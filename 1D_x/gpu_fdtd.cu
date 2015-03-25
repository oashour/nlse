/**********************************************************************************
* Numerical Solution for the Cubic Nonlinear Schrodinger Equation in (1+1)D	  	  *
* using explicit FDTD with second order splitting.                                *
* Coded by: Omar Ashour, Texas A&M University at Qatar, February 2015.    	      *
* ********************************************************************************/
#include "../lib/cu_helpers.h"

// Grid Parameters
#define XN	nodes				// number of spatial nodes
#define TN	100				// number of temporal nodes
#define L	10.0				// Spatial Period
#define TT	10.0                // Max time
#define DX	(2*L / XN)			// spatial step size
#define DT	(TT / TN)			// temporal step size

// Gaussian Pulse Parameters
#define A 1.0
#define R 2.0

// Timing parameters
#define IRVL  100				// Timing interval. Take a reading every N iterations.

// Output files
#define PLOT_F "gpu_fdtd_plot.m"
#define TIME_F "gpu_fdtd_time.m"

// Function Prototypes
__global__ void Re_lin_kernel(double *Re, double *Im, double dt, int xn, double dx);
__global__ void Im_lin_kernel(double *Re, double *Im, double dt, int xn, double dx);
__global__ void nonlin_kernel(double *Re, double *Im, double dt, int xn);

int main(int argc, char *argv[])
{
    // Timing info
	cudaEvent_t begin_event, end_event;
	cudaEventCreate(&begin_event);
	cudaEventCreate(&end_event);
    
	// Print basic info about simulation
	const int nodes = atoi(argv[1]);
	printf("XN: %d. DX: %f, DT: %f, dt/dx^2: %f\n", XN, DX, DT, DT/(DX*DX));

	// Allocate host arrays
    double *h_x 	= (double*)malloc(sizeof(double) * XN);
	double *h_Re 	= (double*)malloc(sizeof(double) * XN);
    double *h_Im	= (double*)malloc(sizeof(double) * XN);   
	double *h_Re_0 	= (double*)malloc(sizeof(double) * XN);
    double *h_Im_0	= (double*)malloc(sizeof(double) * XN);   
	
	// Initial conditions on host
	for(int i = 0; i < XN ; i++)
	{
		h_x[i] = (i-XN/2)*DX;
		h_Re[i]	= sqrt(2.0)/(cosh(h_x[i]));	
		h_Im[i]	= 0;       		 			
		//h_Re[i]	= 2*exp(-(h_x[i]*h_x[i])/2.0/2.0);	
		h_Im_0[i] = h_Im[i];
		h_Re_0[i] = h_Re[i];
	}
    
    // Allocate device arrays and copy from host
	double *d_Re, *d_Im;
	CUDAR_SAFE_CALL(cudaMalloc(&d_Re, sizeof(double) * XN));
	CUDAR_SAFE_CALL(cudaMalloc(&d_Im, sizeof(double) * XN));
	CUDAR_SAFE_CALL(cudaMemcpy(d_Re, h_Re, sizeof(double) * XN, cudaMemcpyHostToDevice));
	CUDAR_SAFE_CALL(cudaMemcpy(d_Im, h_Im, sizeof(double) * XN, cudaMemcpyHostToDevice));

	// Initialize the grid
	dim3 threadsPerBlock(128,1,1);
	dim3 blocksPerGrid((XN + 127)/128,1,1);

	// Timing starts here
	cudaEventRecord(begin_event, 0);

	// Start time evolution
	for (int i = 1; i <= TN; i++)
	{
		// Solve linear part
		Re_lin_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_Re, d_Im, DT*0.5, XN, DX);
		#if CUDAR_ERROR_CHECKING
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		#endif // CUDAR_ERROR_CHECKING
        Im_lin_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_Re, d_Im, DT*0.5, XN, DX);
		#if CUDAR_ERROR_CHECKING
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		#endif // CUDAR_ERROR_CHECKING
		// Solve nonlinear part
		nonlin_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_Re, d_Im, DT, XN);
		#if CUDAR_ERROR_CHECKING
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		#endif // CUDAR_ERROR_CHECKING
		// Solve linear part
		Re_lin_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_Re, d_Im, DT*0.5, XN, DX);
		#if CUDAR_ERROR_CHECKING
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		#endif // CUDAR_ERROR_CHECKING
        Im_lin_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_Re, d_Im, DT*0.5, XN, DX);
		#if CUDAR_ERROR_CHECKING
		CUDAR_SAFE_CALL(cudaPeekAtLastError());
		#endif // CUDAR_ERROR_CHECKING
	}
	float time_value;	
	cudaEventRecord(end_event, 0);
	cudaEventSynchronize(end_event);
	cudaEventElapsedTime(&time_value, begin_event, end_event);

	// Print time to file
	FILE *fp = fopen(TIME_F, "a");
	fprintf(fp, "%f, ", time_value);
	fclose(fp);

	// Copy results to device
	CUDAR_SAFE_CALL(cudaMemcpy(h_Re, d_Re, sizeof(double)*XN, cudaMemcpyDeviceToHost));
	CUDAR_SAFE_CALL(cudaMemcpy(h_Im, d_Im, sizeof(double)*XN, cudaMemcpyDeviceToHost));
	
	// Plot results
	m_plot_1d(h_Re_0, h_Im_0, h_Re, h_Im, L, XN, PLOT_F);
	
	// Clean up 
	free(h_Re); 
	free(h_Im); 
	free(h_Re_0); 
	free(h_Im_0); 
	free(h_x); 
	CUDAR_SAFE_CALL(cudaFree(d_Re)); 
	CUDAR_SAFE_CALL(cudaFree(d_Im)); 

	return 0;
}

__global__ void Re_lin_kernel(double *Re, double *Im, double dt, int xn, double dx)
{                  
	int i = threadIdx.x + blockIdx.x * blockDim.x; 
	
	// Avoid first and last point (boundary conditions)
	if (i >= xn - 1 || i == 0) return; 

	Re[i] = Re[i] - dt/(dx*dx)*(Im[i+1] - 2*Im[i] + Im[i-1]);
}

__global__ void Im_lin_kernel(double *Re, double *Im, double dt, int xn, double dx)
{                  
	int i = threadIdx.x + blockIdx.x * blockDim.x; 
	
	// Avoid first and last point (boundary conditions)
	if (i >= xn - 1 || i == 0) return; 

	Im[i] = Im[i] + dt/(dx*dx)*(Re[i+1] - 2*Re[i] + Re[i-1]);
}

__global__ void nonlin_kernel(double *Re, double *Im, double dt, int xn)
{                  
	int i = threadIdx.x + blockIdx.x * blockDim.x;

	// Avoid first and last point (boundary conditions)
	if (i >= xn - 1 || i == 0) return; 

	double Rp = Re[i]; double Ip = Im[i];
	double A2 = Rp*Rp+Ip*Ip;
	
	Re[i] =	Rp*cos(A2*dt) - Ip*sin(A2*dt);
	Im[i] =	Rp*sin(A2*dt) + Ip*cos(A2*dt);
}

