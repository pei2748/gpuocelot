/*
 * Copyright 1993-2010 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

/*
 * Quadro and Tesla GPUs with compute capability >= 2.0 can overlap two memcopies 
 * with kernel execution. This sample illustrates the usage of CUDA streams to 
 * achieve overlapping of kernel execution with copying data to and from the device. 
 *
 * Additionally, this sample uses CUDA events to measure elapsed time for
 * CUDA calls.  Events are a part of CUDA API and provide a system independent
 * way to measure execution times on CUDA devices with approximately 0.5 
 * microsecond precision.
 *
 * Elapsed times are averaged over nreps repetitions (10 by default).
 *
*/

#include <shrUtils.h>
const char *sSDKname = "simpleMultiCopy";

// includes, system
#include <stdio.h>

// includes, project
#include <sdkHelper.h>  // helper for shared that are common to CUDA SDK samples
#include <shrQATest.h>

////////////////////////////////////////////////////////////////////////////////
// These are CUDA Helper functions

    // This will output the proper CUDA error strings in the event that a CUDA host call returns an error
    #define checkCudaErrors(err)           __checkCudaErrors (err, __FILE__, __LINE__)

    inline void __checkCudaErrors( cudaError err, const char *file, const int line )
    {
        if( cudaSuccess != err) {
		    fprintf(stderr, "%s(%i) : CUDA Runtime API error %d: %s.\n",
                    file, line, (int)err, cudaGetErrorString( err ) );
            exit(-1);
        }
    }

    // This will output the proper error string when calling cudaGetLastError
    #define getLastCudaError(msg)      __getLastCudaError (msg, __FILE__, __LINE__)

    inline void __getLastCudaError( const char *errorMessage, const char *file, const int line )
    {
        cudaError_t err = cudaGetLastError();
        if( cudaSuccess != err) {
            fprintf(stderr, "%s(%i) : getLastCudaError() CUDA error : %s : (%d) %s.\n",
                    file, line, errorMessage, (int)err, cudaGetErrorString( err ) );
            exit(-1);
        }
    }

    // General GPU Device CUDA Initialization
    int gpuDeviceInit(int devID)
    {
        int deviceCount;
        checkCudaErrors(cudaGetDeviceCount(&deviceCount));
        if (deviceCount == 0) {
            fprintf(stderr, "gpuDeviceInit() CUDA error: no devices supporting CUDA.\n");
            exit(-1);
        }
        if (devID < 0) 
            devID = 0;
        if (devID > deviceCount-1) {
            fprintf(stderr, "\n");
            fprintf(stderr, ">> %d CUDA capable GPU device(s) detected. <<\n", deviceCount);
            fprintf(stderr, ">> gpuDeviceInit (-device=%d) is not a valid GPU device. <<\n", devID);
            fprintf(stderr, "\n");
            return -devID;
        }

        cudaDeviceProp deviceProp;
        checkCudaErrors( cudaGetDeviceProperties(&deviceProp, devID) );
        if (deviceProp.major < 1) {
            fprintf(stderr, "gpuDeviceInit(): GPU device does not support CUDA.\n");
            exit(-1);                                                  \
        }

        checkCudaErrors( cudaSetDevice(devID) );
        printf("> gpuDeviceInit() CUDA device [%d]: %s\n", devID, deviceProp.name);
        return devID;
    }

    // This function returns the best GPU (with maximum GFLOPS)
    int gpuGetMaxGflopsDeviceId()
    {
	    int current_device   = 0, sm_per_multiproc = 0;
	    int max_compute_perf = 0, max_perf_device  = 0;
	    int device_count     = 0, best_SM_arch     = 0;
	    cudaDeviceProp deviceProp;

	    cudaGetDeviceCount( &device_count );
	    // Find the best major SM Architecture GPU device
	    while ( current_device < device_count ) {
		    cudaGetDeviceProperties( &deviceProp, current_device );
		    if (deviceProp.major > 0 && deviceProp.major < 9999) {
			    best_SM_arch = MAX(best_SM_arch, deviceProp.major);
		    }
		    current_device++;
	    }

        // Find the best CUDA capable GPU device
        current_device = 0;
        while( current_device < device_count ) {
           cudaGetDeviceProperties( &deviceProp, current_device );
           if (deviceProp.major == 9999 && deviceProp.minor == 9999) {
               sm_per_multiproc = 1;
		   } else {
               sm_per_multiproc = _ConvertSMVer2Cores(deviceProp.major, deviceProp.minor);
           }

           int compute_perf  = deviceProp.multiProcessorCount * sm_per_multiproc * deviceProp.clockRate;
           if( compute_perf  > max_compute_perf ) {
               // If we find GPU with SM major > 2, search only these
               if ( best_SM_arch > 2 ) {
                   // If our device==dest_SM_arch, choose this, or else pass
                   if (deviceProp.major == best_SM_arch) {	
                       max_compute_perf  = compute_perf;
                       max_perf_device   = current_device;
                   }
               } else {
                   max_compute_perf  = compute_perf;
                   max_perf_device   = current_device;
               }
           }
           ++current_device;
	    }
	    return max_perf_device;
    }

    // Initialization code to find the best CUDA Device
    int findCudaDevice(int argc, const char **argv)
    {
        cudaDeviceProp deviceProp;
        int devID = 0;
        // If the command-line has a device number specified, use it
        if (checkCmdLineFlag(argc, argv, "device")) {
            devID = getCmdLineArgumentInt(argc, argv, "device=");
            if (devID < 0) {
                printf("Invalid command line parameters\n");
                exit(-1);
            } else {
                devID = gpuDeviceInit(devID);
                if (devID < 0) {
                   printf("exiting...\n");
                   shrQAFinishExit(argc, (const char **)argv, QA_FAILED);
                   exit(-1);
                }
            }
        } else {
            // Otherwise pick the device with highest Gflops/s
            devID = gpuGetMaxGflopsDeviceId();
            checkCudaErrors( cudaSetDevice( devID ) );
            checkCudaErrors( cudaGetDeviceProperties(&deviceProp, devID) );
            printf("> Using CUDA device [%d]: %s\n", devID, deviceProp.name);
        }
        return devID;
    }
// end of CUDA Helper Functions


// includes, kernels
// Declare the CUDA kernels here and main() code that is needed to launch 
// Compute workload on the system
__global__ void incKernel(int *g_out, int *g_in, int N, int inner_reps)
{ 
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if( idx < N ) {
        for( int i=0; i<inner_reps; ++i ) {        
            g_out[idx] = g_in[idx] + 1;      
        }
    }
}

#define STREAM_COUNT 4

// Uncomment to simulate data source/sink IO times
//#define SIMULATE_IO

int *h_data_source;
int *h_data_sink;

int *h_data_in[STREAM_COUNT];
int *d_data_in[STREAM_COUNT];

int *h_data_out[STREAM_COUNT];
int *d_data_out[STREAM_COUNT];


cudaEvent_t cycleDone[STREAM_COUNT];
cudaStream_t stream[STREAM_COUNT];

cudaEvent_t start, stop;
    
int N = 1 << 22;
int nreps = 10;                 // number of times each experiment is repeated
int inner_reps = 5;

int memsize;

dim3 block(512);
dim3 grid;
    
int thread_blocks;

float processWithStreams(int streams_used);
void init();
bool test();

////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int main(int argc, char *argv[])
{
    int cuda_device = 0;
    float scale_factor;
    cudaDeviceProp deviceProp;	
    
    shrQAStart(argc, argv);
    
    if (checkCmdLineFlag(argc, (const char **)argv, "device")) {
        cuda_device = getCmdLineArgumentInt(argc, (const char **)argv, "device=");
        if (cuda_device < 0) {
            printf("Invalid command line parameters\n");
            exit(-1);
        } else {
           printf("cuda_device = %d\n", cuda_device);
           cuda_device = gpuDeviceInit(cuda_device);
           if (cuda_device < 0) {
              printf("No CUDA Capable devices found, exiting...\n");
              shrQAFinishExit(argc, (const char **)argv, QA_WAIVED);
              exit(-1);
           }
        }
    } else {
       // Otherwise pick the device with the highest Gflops/s
       cuda_device = gpuGetMaxGflopsDeviceId();
       checkCudaErrors( cudaSetDevice( cuda_device ) );
       checkCudaErrors( cudaGetDeviceProperties(&deviceProp, cuda_device) );
       printf("> Using CUDA device [%d]: %s\n", cuda_device, deviceProp.name);
    }

    checkCudaErrors( cudaGetDeviceProperties(&deviceProp, cuda_device) );
    printf("[%s] has %d MP(s) x %d (Cores/MP) = %d (Cores)\n", 
			deviceProp.name, deviceProp.multiProcessorCount,
			_ConvertSMVer2Cores(deviceProp.major, deviceProp.minor),
			_ConvertSMVer2Cores(deviceProp.major, deviceProp.minor) * deviceProp.multiProcessorCount);

    // Anything that is less than 32 Cores will have scaled down workload
    scale_factor = max((32.0f / (_ConvertSMVer2Cores(deviceProp.major, deviceProp.minor) * (float)deviceProp.multiProcessorCount) ), 1.0f);
    N = (int)( (float)N / scale_factor );

    printf("> Device name: %s\n", deviceProp.name);
    printf("> CUDA Capability %d.%d hardware with %d multi-processors\n", 
		deviceProp.major, deviceProp.minor, 
		deviceProp.multiProcessorCount); 
    printf("> scale_factor = %.2f\n", 1.0f/scale_factor);
    printf("> array_size   = %d\n\n", N);

    memsize = N * sizeof(int);

    thread_blocks = N / block.x;
    
    grid.x = thread_blocks % 65535;
    grid.y = (thread_blocks / 65535 + 1);    
 

    // Allocate resources

    h_data_source = (int*) malloc(memsize);
    h_data_sink = (int*) malloc(memsize);    

    for( int i =0; i<STREAM_COUNT; ++i ) {
        
        checkCudaErrors( cudaHostAlloc(&h_data_in[i], memsize, 
			cudaHostAllocDefault) );
        checkCudaErrors( cudaMalloc(&d_data_in[i], memsize) );
        
        checkCudaErrors( cudaHostAlloc(&h_data_out[i], memsize, 
			cudaHostAllocDefault) );
        checkCudaErrors( cudaMalloc(&d_data_out[i], memsize) );

        checkCudaErrors( cudaStreamCreate(&stream[i]) );
        checkCudaErrors( cudaEventCreate(&cycleDone[i]) ); 
        
        cudaEventRecord(cycleDone[i], stream[i]);
    }

    cudaEventCreate(&start); cudaEventCreate(&stop);

    init();

    // Kernel warmup
    incKernel<<<grid, block>>>(d_data_out[0], d_data_in[0], N, inner_reps);

    
    // Time copies and kernel    
    cudaEventRecord(start,0);
    checkCudaErrors( cudaMemcpyAsync(d_data_in[0], h_data_in[0], memsize, 
		cudaMemcpyHostToDevice,0) );
    cudaEventRecord(stop,0);
    cudaEventSynchronize(stop);
    
    float memcpy_h2d_time;    
    cudaEventElapsedTime(&memcpy_h2d_time, start, stop);

    cudaEventRecord(start,0);
    checkCudaErrors( cudaMemcpyAsync(h_data_out[0], d_data_out[0], memsize, 
		cudaMemcpyDeviceToHost, 0) );        
    cudaEventRecord(stop,0);
    cudaEventSynchronize(stop);
    
    float memcpy_d2h_time;    
    cudaEventElapsedTime(&memcpy_d2h_time, start, stop);
    
    cudaEventRecord(start,0);
    incKernel<<<grid, block,0,0>>>(d_data_out[0], d_data_in[0], N, inner_reps);
    cudaEventRecord(stop,0);
    cudaEventSynchronize(stop);
    
    float kernel_time;    
    cudaEventElapsedTime(&kernel_time, start, stop);
    
    printf("\n");
    printf("Relevant properties of this CUDA device\n");	
    printf("(%s) Can overlap one CPU<>GPU data transfer with GPU kernel execution (device property \"deviceOverlap\")\n", deviceProp.deviceOverlap ? "X" : " ");
    //printf("(%s) Can execute several GPU kernels simultaneously (compute capability >= 2.0)\n", deviceProp.major >= 2 ? "X": " ");
    printf("(%s) Can overlap two CPU<>GPU data transfers with GPU kernel execution\n"
	   "    (compute capability >= 2.0 AND (Tesla product OR Quadro 4000/5000)\n", 
	   (deviceProp.major == 2 && strstr(deviceProp.name, "GeForce") == 0 
	    && strstr(deviceProp.name, "Quadro 2000") == 0
	    && strstr(deviceProp.name, "Quadro 600") == 0)
	   ? "X" : " ");

    printf("\n");
    printf("Measured timings (throughput):\n");
    printf(" Memcpy host to device\t: %f ms (%f GB/s)\n", 
		memcpy_h2d_time, (memsize * 1e-6)/ memcpy_h2d_time );
    printf(" Memcpy device to host\t: %f ms (%f GB/s)\n", 
		memcpy_d2h_time, (memsize * 1e-6)/ memcpy_d2h_time);
    printf(" Kernel\t\t\t: %f ms (%f GB/s)\n", 
		kernel_time, (inner_reps * memsize * 2e-6)/ kernel_time);
	   
    printf("\n");
    printf("Theoretical limits for speedup gained from overlapped data transfers:\n");
    printf("No overlap at all (transfer-kernel-transfer): %f ms \n", 
	   memcpy_h2d_time + memcpy_d2h_time + kernel_time);
    printf("Compute can overlap with one transfer: %f ms\n",
	   max((memcpy_h2d_time + memcpy_d2h_time), kernel_time));
    printf("Compute can overlap with both data transfers: %f ms\n",
	   max(max(memcpy_h2d_time,memcpy_d2h_time), kernel_time));
    
	  // Process pipelined work
    float serial_time = processWithStreams(1);  
    float overlap_time = processWithStreams(STREAM_COUNT);  

    printf("\nAverage measured timings over %d repetitions:\n", nreps);
    printf(" Avg. time when execution fully serialized\t: %f ms\n", 
		serial_time / nreps);
    printf(" Avg. time when overlapped using %d streams\t: %f ms\n", 
		STREAM_COUNT, overlap_time / nreps);
    printf(" Avg. speedup gained (serialized - overlapped)\t: %f ms\n", 
		(serial_time - overlap_time) / nreps);

    printf("\nMeasured throughput:\n");    
    printf(" Fully serialized execution\t\t: %f GB/s\n", 
		(nreps * (memsize * 2e-6))/ serial_time);
    printf(" Overlapped using %d streams\t\t: %f GB/s\n", 
		STREAM_COUNT, (nreps * (memsize * 2e-6))/ overlap_time);
    
    // Verify the results, we will use the results for final output
    bool bResults = test();

    // Free resources

    free( h_data_source );
    free( h_data_sink );

    for( int i =0; i<STREAM_COUNT; ++i ) {
        
        cudaFreeHost(h_data_in[i]);
        cudaFree(d_data_in[i]);

        cudaFreeHost(h_data_out[i]);
        cudaFree(d_data_out[i]);
        
        cudaStreamDestroy(stream[i]);
        cudaEventDestroy(cycleDone[i]);        
    }
    
    cudaEventDestroy(start);
    cudaEventDestroy(stop);
    
    cudaDeviceReset();

    // Test result
    shrQAFinishExit(argc, (const char **)argv, (bResults ? QA_PASSED : QA_FAILED));
}

float processWithStreams(int streams_used) {
    
    int current_stream = 0;

    float time;

    // Do processing in a loop
    //
    // Note: All memory commands are processed in the order  they are issued, 
    // independent of the stream they are enqueued in. Hence the pattern by 
    // which the copy and kernel commands are enqueued in the stream 
    // has an influence on the achieved overlap.

    cudaEventRecord(start, 0);
    for( int i=0; i<nreps; ++i ) {
        int next_stream = (current_stream + 1 ) % streams_used;

#ifdef SIMULATE_IO
        // Store the result
        memcpy(h_data_sink, h_data_out[current_stream],memsize);            

        // Read new input        
        memcpy(h_data_in[next_stream], h_data_source, memsize);
#endif

        // Ensure that processing and copying of the last cycle has finished
        cudaEventSynchronize(cycleDone[next_stream]);

        // Process current frame
        incKernel<<<grid, block, 0, stream[current_stream]>>>(
			d_data_out[current_stream],
			d_data_in[current_stream], 
			N, 
			inner_reps);
        
        // Upload next frame
        checkCudaErrors( cudaMemcpyAsync(
			d_data_in[next_stream], 
			h_data_in[next_stream], 
			memsize, 
			cudaMemcpyHostToDevice, 
			stream[next_stream]) );

        // Download current frame
        checkCudaErrors( cudaMemcpyAsync(
			h_data_out[current_stream], 
			d_data_out[current_stream], 
			memsize, 
			cudaMemcpyDeviceToHost, 
			stream[current_stream]) );    
        
        checkCudaErrors( cudaEventRecord(
			cycleDone[current_stream], 
			stream[current_stream]) );
        
        current_stream = next_stream;
    }
    cudaEventRecord(stop, 0);    

    cudaDeviceSynchronize();

    cudaEventElapsedTime(&time, start, stop);

    return time;

}

void init() {    
    for( int i=0; i<N; ++i) {        
        h_data_source[i] = 0;
    }
    
    for( int i =0; i<STREAM_COUNT; ++i ) {
        memcpy(h_data_in[i], h_data_source, memsize);        
    }
}


bool test() {

    bool passed = true;

    for( int j =0; j<STREAM_COUNT; ++j ) {
        for( int i =0; i<N; ++i ) {
            passed &= (h_data_out[j][i] == 1);
        }
    }

    return passed;
}
