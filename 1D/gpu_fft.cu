/**********************************************************************************
* Numerical Solution for the Cubic Nonlinear Schrodinger Equation        		  *
* using second order split step Fourier method.                                   *
* Coded by: Omar Ashour, Texas A&M University at Qatar, February 2015.    	      *
**********************************************************************************/
#include <sys/time.h>
#include <stddef.h>
#include "../lib/cu_helpers.h"
#include <cufft.h>

// Grid Parameters
#define XN	2048					// Number of x-spatial nodes
#define TN	10000					// Number of temporal nodes
#define LX	10.0					// x-spatial domain [-LX,LX)
#define TT	100.0            		// Max time
#define DX	(2*LX / XN)				// x-spatial step size
#define DT	(TT / TN)    			// temporal step size

// Function prototypes
__global__ void nonlin(cufftDoubleComplex *psi, double dt);
__global__ void lin(cufftDoubleComplex *psi, double *k2, double dt);
__global__ void normalize(cufftDoubleComplex *psi, int size);

int main(void)
{                                                                          
	// Allocate and initialize the arrays
    double *x = (double*)malloc(sizeof(double) * XN);
	double *h_k2 = (double*)malloc(sizeof(double) * XN);
	cufftDoubleComplex *h_psi = (cufftDoubleComplex*)
										malloc(sizeof(cufftDoubleComplex)*XN);
	cufftDoubleComplex *h_psi_0 = (cufftDoubleComplex*)
										malloc(sizeof(cufftDoubleComplex)*XN);
	
	// Create transform plans
    cufftHandle plan;
    CUFFT_SAFE_CALL(cufftPlan1d(&plan, XN, CUFFT_Z2Z, 1));

    // X and Y wave numbers
	double dkx = 2*M_PI/XN/DX;
	double *kx = (double*)malloc(XN * sizeof(double));
	for(int i = XN/2; i >= 0; i--) 
		kx[XN/2 - i]=(XN/2 - i) * dkx;
	for(int i = XN/2+1; i < XN; i++) 
		kx[i]=(i - XN) * dkx; 

	// initialize x.
	for(int i = 0; i < XN ; i++)
		x[i] = (i-XN/2)*DX;
	
	// Initial Conditions and square of wave number
	for(int i = 0; i < XN; i++)
		{
			h_psi[i].x = sqrt(2)/cosh(x[i]);
			//h_psi[i].x = 2*exp(-(x[i]*x[i]/2.0/2.0));
			h_psi[i].y = 0;
			h_psi_0[i].x = h_psi[i].x;
			h_psi_0[i].y = h_psi[i].y;
			h_k2[i] = kx[i]*kx[i];
		}   
	
	// Allocate and copy device memory
    cufftDoubleComplex *d_psi; double *d_k2;
	CUDAR_SAFE_CALL(cudaMalloc((void **)&d_psi, sizeof(cufftDoubleComplex)*XN));
	CUDAR_SAFE_CALL(cudaMalloc((void **)&d_k2, sizeof(double)*XN));
    CUDAR_SAFE_CALL(cudaMemcpy(d_psi, h_psi, sizeof(cufftDoubleComplex)*XN, cudaMemcpyHostToDevice));
    CUDAR_SAFE_CALL(cudaMemcpy(d_k2, h_k2, sizeof(double)*XN, cudaMemcpyHostToDevice));
	
	// initialize the grid
	dim3 threadsPerBlock(128,1,1);
	dim3 blocksPerGrid((XN + 127)/128,1,1);

	for (int i = 1; i < TN; i++)
	{
		// forward transform
    	CUFFT_SAFE_CALL(cufftExecZ2Z(plan, d_psi, d_psi, CUFFT_FORWARD));
		// linear calculation
		lin<<<blocksPerGrid, threadsPerBlock>>>(d_psi, d_k2, DT/2);  
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		// backward transform
    	CUFFT_SAFE_CALL(cufftExecZ2Z(plan, d_psi, d_psi, CUFFT_INVERSE));
		// normalize the transform
		normalize<<<blocksPerGrid, threadsPerBlock>>>(d_psi, XN);
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		// nonlinear calculation
		nonlin<<<blocksPerGrid, threadsPerBlock>>>(d_psi, DT);
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		// forward transform
    	CUFFT_SAFE_CALL(cufftExecZ2Z(plan, d_psi, d_psi, CUFFT_FORWARD));
		// linear calculation
		lin<<<blocksPerGrid, threadsPerBlock>>>(d_psi, d_k2, DT/2);  
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		// backward transform
    	CUFFT_SAFE_CALL(cufftExecZ2Z(plan, d_psi, d_psi, CUFFT_INVERSE));
		// normalize the transform
		normalize<<<blocksPerGrid, threadsPerBlock>>>(d_psi, XN);
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
	}

	CUDAR_SAFE_CALL(cudaMemcpy(h_psi, d_psi, sizeof(cufftDoubleComplex)*XN, cudaMemcpyDeviceToHost));
	// plot results
	cm_plot_1d(h_psi_0, h_psi, LX, XN, "plotting.m");

	// garbage collection
	CUFFT_SAFE_CALL(cufftDestroy(plan));
	free(x);
	free(h_k2);
	free(kx);
    free(h_psi_0);
	free(h_psi);
	CUDAR_SAFE_CALL(cudaFree(d_psi));
	CUDAR_SAFE_CALL(cudaFree(d_k2));
	return 0;
}

__global__ void nonlin(cufftDoubleComplex *psi, double dt)
{                  
	int i = threadIdx.x + blockIdx.x * blockDim.x; 
    
	double psi2 = cuCabs(psi[i])*cuCabs(psi[i]);
    cufftDoubleComplex expo = make_cuDoubleComplex(cos(psi2*dt), sin(psi2*dt));
	psi[i] = cuCmul(psi[i], expo);
}

__global__ void lin(cufftDoubleComplex *psi, double *k2, double dt)
{                  
	int i = threadIdx.x + blockIdx.x * blockDim.x; 
	
    cufftDoubleComplex expo = make_cuDoubleComplex(cos(k2[i]*dt), -sin(k2[i]*dt));
	psi[i] = cuCmul(psi[i], expo);
}

__global__ void normalize(cufftDoubleComplex *psi, int size)
{
	int i = threadIdx.x + blockIdx.x * blockDim.x; 

	psi[i].x = psi[i].x/size; psi[i].y = psi[i].y/size;
}
