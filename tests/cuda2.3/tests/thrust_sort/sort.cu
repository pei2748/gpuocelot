#ifdef _GLIBCXX_USE_INT128
#undef _GLIBCXX_USE_INT128
#endif 

#ifdef _GLIBCXX_ATOMIC_BUILTINS
#undef _GLIBCXX_ATOMIC_BUILTINS
#endif

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/generate.h>
#include <thrust/sort.h>
#include <cstdlib>

int main(void)
{
  // generate random data on the host
  thrust::host_vector<int> h_vec(20);
  thrust::generate(h_vec.begin(), h_vec.end(), rand);

  // transfer to device
  thrust::device_vector<int> d_vec = h_vec;

  // sort on device
  thrust::sort(d_vec.begin(), d_vec.end());

  std::cout << "TEST PASSED\n";

  return 0;
}
