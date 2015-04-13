/**
 * gemm.cu: This file is part of the PolyBench/GPU 1.0 test suite.
 *
 *
 * Contact: Scott Grauer-Gray <sgrauerg@gmail.com>
 * Louis-Noel Pouchet <pouchet@cse.ohio-state.edu>
 * Web address: http://www.cse.ohio-state.edu/~pouchet/software/polybench/GPU
 */

#include <unistd.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <cuda.h>

#include "../../common/polybenchUtilFuncts.h"

#define GPU_DEVICE 0

//define the error threshold for the results "not matching"
#define PERCENT_DIFF_ERROR_THRESHOLD 0.05

/* Problem size */
#define NI 512
#define NJ 512
#define NK 512

/* Thread block dimensions */
#define DIM_THREAD_BLOCK_X 32
#define DIM_THREAD_BLOCK_Y 8

/* Declared constant values for ALPHA and BETA (same as values in PolyBench 2.0) */
#define ALPHA 32412.0f
#define BETA 2123.0f

/* Can switch DATA_TYPE between float and double */
typedef float DATA_TYPE;



void gemm(DATA_TYPE *A, DATA_TYPE *B, DATA_TYPE *C)
{
	int i,j,k;
	
	for (i = 0; i < NI; i++)
	{
    	for (j = 0; j < NJ; j++)
    	{
			C[i*NJ + j] *= BETA;
	
			for (k = 0; k < NK; ++k)
			{
	  			C[i*NJ + j] += ALPHA * A[i*NK + k] * B[k*NJ + j];
			}
      	}
	}
}


void init(DATA_TYPE *A, DATA_TYPE *B, DATA_TYPE *C)
{
	int i, j;

  	for (i = 0; i < NI; i++)
	{
    	for (j = 0; j < NK; j++)
		{
      		A[i*NK + j] = ((DATA_TYPE) i*j) / NI;
		}
	}

  	for (i = 0; i < NK; i++)
	{
    	for (j = 0; j < NJ; j++)
		{
      		B[i*NJ + j] = ((DATA_TYPE) i*j + 1) / NJ;
		}
	}

  	for (i = 0; i < NI; i++)
	{
    	for (j = 0; j < NJ; j++)
		{
      		C[i*NJ + j] = ((DATA_TYPE) i*j + 2) / NJ;
		}
	}
}


void compareResults(DATA_TYPE* C, DATA_TYPE* C_outputFromGpu)
{
	int i, j, fail;
	fail = 0;
	
	// Compare C1 and C2
	for (i=0; i < NI; i++) 
	{
		for (j=0; j < NJ; j++) 
		{
			if (percentDiff(C[i*NJ + j], C_outputFromGpu[i*NJ + j]) > PERCENT_DIFF_ERROR_THRESHOLD) 
			{
				fail++;
			}
		}
	}
	
	// Print results
	printf("Non-Matching CPU-GPU Outputs Beyond Error Threshold of %4.2f Percent: %d\n", PERCENT_DIFF_ERROR_THRESHOLD, fail);
}


void GPU_argv_init()
{
	cudaDeviceProp deviceProp;
	cudaGetDeviceProperties(&deviceProp, GPU_DEVICE);
	printf("setting device %d with name %s\n",GPU_DEVICE,deviceProp.name);
	cudaSetDevice( GPU_DEVICE );
}

/**
 * Kernel to update. TODO:
 *  - Shared memory
 *  - Iterate over the elements
 *  - Diff this to the simple matrix multiplication
 *      - Memory is multiplied by BETA and then added, not overriden,
 *      - Memory is retrieved (simply n x m extra ops)
 *      - Each element is also multiplied by ALPHA
 */
__global__ void gemm_kernel(DATA_TYPE *a, DATA_TYPE *b, DATA_TYPE *c)
{
        /* Allocate shared memory */
        __shared__ DATA_TYPE s_a[256];
        __shared__ DATA_TYPE s_b[256];
        
        /* Column, A.w, {0, ... NJ} */
	int j = blockIdx.x * blockDim.x + threadIdx.x;
        /* Row, B.h, {0, ... NI} */
	int i = blockIdx.y * blockDim.y + threadIdx.y;
        
        /* Compute offset idx for A & B */
	// First A index - BlockRow*BlockWidth*Width-A
	int a_0 = NJ * 16 * blockIdx.y;
	// aBegin -> last element in row -> + width - 1
	int a_last = a_0 + NJ - 1;
	// Column block iteration = blockDim.x
	int a_plus = 16;
	// b_0 -> Column Shift
	int b_0 = 16 * blockIdx.x;
        // Row block iteration = blockDim.y * width B
	int b_plus = 16 * NI;
        
        /* Fetch once, then multiply and store in register */
        DATA_TYPE sum = c[i * NJ + j];
        
        /* Iterate over blocks moving to right over A, downwards over B indexes */
        int a_i, b_i;
        for(a_i = a_0, b_i = b_0; a_i <= a_last; a_i += a_plus, b_i += b_plus)
        {
                /* Fetch global to local memory */
                // Each thread grabs two global memory pieces out of 266*2
		// (a is the dynamic start, ty is the row (needs to be accounted for whole matrix size)
		// tx is the column, can be just added
                s_a[threadIdx.y*16 + threadIdx.x] = a[a_i + threadIdx.y * NJ + threadIdx.x];
		s_b[threadIdx.y*16 + threadIdx.x] = b[b_i + threadIdx.y * NI + threadIdx.x];
                __syncthreads();
                
                /* Sum over NK */
                int k;
                for(k=0; k<NK; k++)
                {
                        /* C = BETA*C + ALPHA*(A x B) */
                        sum += ALPHA * s_a[threadIdx.y * 16 + k] * s_b[k * 16 + threadIdx.x];
                }
        }
        
        c[i * NJ + j] = sum;
        
        // DEFAULT WORK, KEEPING IT FOR REFERENCE, 
        //    IT MAY BE USEFUL FOR PRESENTATION, DEBUGGING ETC ETC!!!
        
        /* Check if both i and j are within boundaries */
//	if ((i < NI) && (j < NJ))
//	{	
//                /* Multiply previous c value by Beta, retrieve and store, BAD */
//		c[i * NJ + j] *= BETA;
//                /* Sum over NK */
//		int k;
//		for(k=0; k < NK; k++)
//		{
//                        /* C = C*BETA + ALPHA*(A x B) */
//			c[i * NJ + j] += ALPHA * a[i * NK + k] * b[k * NJ +j];
//		}
//	}
}


void gemmCuda(DATA_TYPE* A, DATA_TYPE* B, DATA_TYPE* C, DATA_TYPE* C_outputFromGpu)
{
	double t_start, t_end;

	DATA_TYPE *A_gpu;
	DATA_TYPE *B_gpu;
	DATA_TYPE *C_gpu;

	cudaMalloc((void **)&A_gpu, sizeof(DATA_TYPE) * NI * NK);
	cudaMalloc((void **)&B_gpu, sizeof(DATA_TYPE) * NK * NJ);
	cudaMalloc((void **)&C_gpu, sizeof(DATA_TYPE) * NI * NJ);
	
	cudaMemcpy(A_gpu, A, sizeof(DATA_TYPE) * NI * NK, cudaMemcpyHostToDevice);
	cudaMemcpy(B_gpu, B, sizeof(DATA_TYPE) * NK * NJ, cudaMemcpyHostToDevice);
	cudaMemcpy(C_gpu, C, sizeof(DATA_TYPE) * NI * NJ, cudaMemcpyHostToDevice);
	
	dim3 block(DIM_THREAD_BLOCK_X, DIM_THREAD_BLOCK_Y);
	dim3 grid((size_t)(ceil( ((float)NI)/ ((float)block.x) )),(size_t)(ceil( ((float)NJ)/ ((float)block.y) )));

	t_start = rtclock();

	gemm_kernel<<< grid, block >>>(A_gpu, B_gpu, C_gpu);
	cudaThreadSynchronize();

	t_end = rtclock();
	fprintf(stdout, "GPU Runtime: %0.6lfs\n", t_end - t_start);

	cudaMemcpy(C_outputFromGpu, C_gpu, sizeof(DATA_TYPE) * NI * NJ, cudaMemcpyDeviceToHost);    
	
	cudaFree(A_gpu);
	cudaFree(B_gpu);
	cudaFree(C_gpu);
}
	

int main(int argc, char *argv[])
{
	double t_start, t_end;

	DATA_TYPE* A;
	DATA_TYPE* B;  
	DATA_TYPE* C;  
	DATA_TYPE* C_outputFromGpu; 

	A = (DATA_TYPE*)malloc(NI*NK*sizeof(DATA_TYPE)); 
	B = (DATA_TYPE*)malloc(NK*NJ*sizeof(DATA_TYPE));   
	C = (DATA_TYPE*)malloc(NI*NJ*sizeof(DATA_TYPE)); 
	C_outputFromGpu = (DATA_TYPE*)malloc(NI*NJ*sizeof(DATA_TYPE)); 

	init(A, B, C);
	
	GPU_argv_init();
	
	gemmCuda(A, B, C, C_outputFromGpu);

	t_start = rtclock();	
	gemm(A, B, C);
	t_end = rtclock();
	fprintf(stdout, "CPU Runtime: %0.6lfs\n", t_end - t_start);
	
	compareResults(C, C_outputFromGpu);

	free(A);
	free(B);  
	free(C);  
	free(C_outputFromGpu); 

    	return 0;
}

