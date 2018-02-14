#ifndef PERMUTOHEDRAL_CU
#define PERMUTOHEDRAL_CU

#define BLOCK_SIZE 256

#include <cstdio>

#include "cuda_code_indexing.h"
#include "cuda_runtime.h"
#include <stdexcept>


//64 bit implementation not implemented for compute capability < 6.0
// none trivial performance cost for compute capability < 6.0
#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ >= 600
#else
__device__ double atomicAdd(double* address, double val)
{
    unsigned long long int* address_as_ull = (unsigned long long int*)address;
    unsigned long long int old = *address_as_ull, assumed;
    do {
        assumed = old;
        old = atomicCAS(address_as_ull, assumed,
                        __double_as_longlong(val + __longlong_as_double(assumed)));
    } while (assumed != old);
    return __longlong_as_double(old);
}

#endif



template<typename T, int pd, int vd>class HashTableGPU{
public:
    int capacity;
    T * values;
    short * keys;
    int * entries;
    bool original; //is this the original table or a copy?

    HashTableGPU(int capacity_): capacity(capacity_), values(nullptr), keys(nullptr), entries(nullptr), original(true){

        cudaMalloc((void**)&values, capacity*vd*sizeof(T));
        cudaMemset((void *)values, 0, capacity*vd*sizeof(T));

        cudaMalloc((void **)&entries, capacity*2*sizeof(int));
        cudaMemset((void *)entries, -1, capacity*2*sizeof(int));

        cudaMalloc((void **)&keys, capacity*pd*sizeof(short));
        cudaMemset((void *)keys, 0, capacity*pd*sizeof(short));
    }

    HashTableGPU(const HashTableGPU& table):capacity(table.capacity), values(table.values), keys(table.keys), entries(table.entries), original(false){}

    ~HashTableGPU(){
        // only free if it is the original table
        if(original){
            cudaFree(values);
            cudaFree(entries);
            cudaFree(keys);
        }
    }

    void resetHashTable() {
        cudaMemset((void*)values, 0, capacity*vd*sizeof(T));
    }

    __device__ int modHash(unsigned int n){
        return(n % (2 * capacity));
    }

    __device__ unsigned int hash(short *key) {
        unsigned int k = 0;
        for (int i = 0; i < pd; i++) {
            k += key[i];
            k = k * 2531011;
        }
        return k;
    }

    __device__ int insert(short *key, unsigned int slot) {
        int h = modHash(hash(key));
        while (1) {
            int *e = entries + h;

            // If the cell is empty (-1), lock it (-2)
            int contents = atomicCAS(e, -1, -2);

            if (contents == -2){
                // If it was locked already, move on to the next cell
            }else if (contents == -1) {
                // If it was empty, we successfully locked it. Write our key.
                for (int i = 0; i < pd; i++) {
                    keys[slot*pd+i] = key[i];
                }
                // Unlock
                atomicExch(e, slot);
                return h;
            } else {
                // The cell is unlocked and has a key in it, check if it matches
                bool match = true;
                for (int i = 0; i < pd && match; i++) {
                    match = (keys[contents*pd+i] == key[i]);
                }
                if (match)
                    return h;
            }
            // increment the bucket with wraparound
            h++;
            if (h == capacity*2)
                h = 0;
        }
    }

    __device__ int retrieve(short *key) {

        int h = modHash(hash(key));
        while (1) {
            int *e = entries + h;

            if (*e == -1)
                return -1;

            bool match = true;
            for (int i = 0; i < pd && match; i++) {
                match = (keys[(*e)*pd+i] == key[i]);
            }
            if (match)
                return *e;

            h++;
            if (h == capacity*2)
                h = 0;
        }
    }
};



template<typename T> struct MatrixEntry {
    int index;
    T weight;
};

template<typename T, int pd, int vd>
__global__ static void createLattice(const int n,
                                     const T *positions,
                                     const T *scaleFactor,
                                     const int * canonical,
                                     MatrixEntry<T> *matrix,
                                     HashTableGPU<T, pd, vd> table) {

    const int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx >= n)
        return;


    T elevated[pd + 1];
    const T *position = positions + idx * pd;
    int rem0[pd + 1];
    int rank[pd + 1];


    T sm = 0;
    for (int i = pd; i > 0; i--) {
        T cf = position[i - 1] * scaleFactor[i - 1];
        elevated[i] = sm - i * cf;
        sm += cf;
    }
    elevated[0] = sm;


    // Find the closest 0-colored simplex through rounding
    // greedily search for the closest zero-colored lattice point
    short sum = 0;
    for (int i = 0; i <= pd; i++) {
        T v = elevated[i] * (1.0f / (pd + 1));
        T up = ceil(v) * (pd + 1);
        T down = floor(v) * (pd + 1);
        if (up - elevated[i] < elevated[i] - down) {
            rem0[i] = (short) up;
        } else {
            rem0[i] = (short) down;
        }
        sum += rem0[i];
    }
    sum /= pd + 1;

    /*
    // Find the simplex we are in and store it in rank (where rank describes what position coordinate i has in the sorted order of the features values)
    for (int i = 0; i <= pd; i++)
        rank[i] = 0;
    for (int i = 0; i < pd; i++) {
        double di = elevated[i] - rem0[i];
        for (int j = i + 1; j <= pd; j++)
            if (di < elevated[j] - rem0[j])
                rank[i]++;
            else
                rank[j]++;
    }

    // If the point doesn't lie on the plane (sum != 0) bring it back
    for (int i = 0; i <= pd; i++) {
        rank[i] += sum;
        if (rank[i] < 0) {
            rank[i] += pd + 1;
            rem0[i] += pd + 1;
        } else if (rank[i] > pd) {
            rank[i] -= pd + 1;
            rem0[i] -= pd + 1;
        }
    }
    */

    // sort differential to find the permutation between this simplex and the canonical one
    for (int i = 0; i <= pd; i++) {
        rank[i] = 0;
        for (int j = 0; j <= pd; j++) {
            if (elevated[i] - rem0[i] < elevated[j] - rem0[j] || (elevated[i] - rem0[i] == elevated[j] - rem0[j] && i > j)) {
                rank[i]++;
            }
        }
    }

    if (sum > 0) { // sum too large, need to bring down the ones with the smallest differential
        for (int i = 0; i <= pd; i++) {
            if (rank[i] >= pd + 1 - sum) {
                rem0[i] -= pd + 1;
                rank[i] += sum - (pd + 1);
            } else {
                rank[i] += sum;
            }
        }
    } else if (sum < 0) { // sum too small, need to bring up the ones with largest differential
        for (int i = 0; i <= pd; i++) {
            if (rank[i] < -sum) {
                rem0[i] += pd + 1;
                rank[i] += (pd + 1) + sum;
            } else {
                rank[i] += sum;
            }
        }
    }

    T barycentric[pd + 2]{0};

    // turn delta into barycentric coords

    for (int i = 0; i <= pd; i++) {
        T delta = (elevated[i] - rem0[i]) * (1.0f / (pd + 1));
        barycentric[pd - rank[i]] += delta;
        barycentric[pd + 1 - rank[i]] -= delta;
    }
    barycentric[0] += 1.0f + barycentric[pd + 1];


    short key[pd];
    for (int remainder = 0; remainder <= pd; remainder++) {
        // Compute the location of the lattice point explicitly (all but
        // the last coordinate - it's redundant because they sum to zero)

        /*for (int i = 0; i < pd; i++)
            key[i] = static_cast<short>(rem0[i] + canonical[remainder * (pd + 1) + rank[i]]);*/
        for (int i = 0; i < pd; i++) {
            key[i] = static_cast<short>(rem0[i] + remainder);
            if (rank[i] > pd - remainder)
                key[i] -= (pd + 1);
        }

        MatrixEntry<T> r;
        unsigned int slot = static_cast<unsigned int>(idx * (pd + 1) + remainder);
        r.index = table.insert(key, slot);
        r.weight = barycentric[remainder];
        matrix[idx * (pd + 1) + remainder] = r;
    }
}

template<typename T, int pd, int vd>
__global__ static void cleanHashTable(int n, HashTableGPU<T, pd, vd> table) {

    const int idx = (blockIdx.y * gridDim.x + blockIdx.x) * blockDim.x * blockDim.y + threadIdx.x;

    if (idx >= n)
        return;

    // find my hash table entry
    int *e = table.entries + idx;

    // Check if I created my own key in the previous phase
    if (*e >= 0) {
        // Rehash my key and reset the pointer in order to merge with
        // any other pixel that created a different entry under the
        // same key. If the computation was serial this would never
        // happen, but sometimes race conditions can make the same key
        // be inserted twice. hashTableRetrieve always returns the
        // earlier, so it's no problem as long as we rehash now.
        *e = table.retrieve(table.keys + *e * pd);
    }
}

template<typename T, int pd, int vd>
__global__ static void splatCache(const int n, const T *values, MatrixEntry<T> *matrix, HashTableGPU<T, pd, vd> table) {

    const int idx = threadIdx.x + blockIdx.x * blockDim.x;
    const int threadId = threadIdx.x;
    const int color = blockIdx.y;
    const bool outOfBounds = (idx >= n);

    __shared__ int sharedOffsets[BLOCK_SIZE];
    __shared__ T sharedValues[BLOCK_SIZE * vd];
    int myOffset = -1;
    T *myValue = sharedValues + threadId * vd;

    if (!outOfBounds) {

        T *value = const_cast<T *>(values + idx * (vd - 1));

        MatrixEntry<T> r = matrix[idx * (pd + 1) + color];

        // convert the matrix entry from a pointer into the entries array to a pointer into the keys/values array
        matrix[idx * (pd + 1) + color].index = r.index = table.entries[r.index];
        // record the offset into the keys/values array in shared space
        myOffset = sharedOffsets[threadId] = r.index * vd;

        for (int j = 0; j < vd - 1; j++) {
            myValue[j] = value[j] * r.weight;
        }
        myValue[vd - 1] = r.weight;

    } else {
        sharedOffsets[threadId] = -1;
    }

    __syncthreads();

    // am I the first thread in this block to care about this key?
    if (outOfBounds)
        return;

    for (int i = 0; i < BLOCK_SIZE; i++) {
        if (i < threadId) {
            if (myOffset == sharedOffsets[i]) {
                // somebody else with higher priority cares about this key
                return;
            }
        } else if (i > threadId) {
            if (myOffset == sharedOffsets[i]) {
                // someone else with lower priority cares about this key, accumulate it into mine
                for (int j = 0; j < vd; j++) {
                    sharedValues[threadId * vd + j] += sharedValues[i * vd + j];
                }
            }
        }
    }

    // only the threads with something to write to main memory are still going
    T *val = table.values + myOffset;
    for (int j = 0; j < vd; j++) {
        atomicAdd(val + j, myValue[j]);
    }
}

template<typename T, int pd, int vd>
__global__ static void blur(int n, T *newValues, MatrixEntry<T> *matrix, int color, HashTableGPU<T, pd, vd> table) {

    const int idx = (blockIdx.y * gridDim.x + blockIdx.x) * blockDim.x * blockDim.y + threadIdx.x;
    if (idx >= n)
        return;

    // Check if I'm valid
    if (matrix[idx].index != idx)
        return;


    // find my key and the keys of my neighbors
    short myKey[pd + 1];
    short np[pd + 1];
    short nm[pd + 1];


    for (int i = 0; i < pd; i++) {
        myKey[i] = table.keys[idx * pd + i];
        np[i] = myKey[i] + 1;
        nm[i] = myKey[i] - 1;
    }
    np[color] -= pd + 1;
    nm[color] += pd + 1;

    int offNp = table.retrieve(np);
    int offNm = table.retrieve(nm);

    //in case neighbours don't exist (lattice edges) offNp and offNm are -1
    T zeros[vd]{0};
    T *valNp = zeros;
    T *valNm = zeros;
    if(offNp >= 0)
        valNp = table.values + vd * offNp;
    if(offNm >= 0)
        valNm = table.values + vd * offNm;

    T *valMe = table.values + vd * idx;
    T *valOut = newValues + vd * idx;

    for (int i = 0; i < vd; i++)
        valOut[i] = 0.25 * valNp[i] + 0.5 * valMe[i] + 0.25 * valNm[i];
    //valOut[i] = 0.5f * valNp[i] + 1.0f * valMe[i] + 0.5f * valNm[i];


}

template<typename T, int pd, int vd>
__global__ static void slice(const int n, T *values, MatrixEntry<T> *matrix, HashTableGPU<T, pd, vd> table) {

    const int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx >= n)
        return;

    T value[vd-1]{0};
    T weight = 0;

    for (int i = 0; i <= pd; i++) {
        MatrixEntry<T> r = matrix[idx * (pd + 1) + i];
        T *val = table.values + r.index * vd;
        for (int j = 0; j < vd - 1; j++) {
            value[j] += r.weight * val[j];
        }
        weight += r.weight * val[vd - 1];
    }

    weight = 1.0f / weight;
    for (int j = 0; j < vd - 1; j++)
        values[idx * (vd - 1) + j] = value[j] * weight;

}


template<typename T, int pd, int vd>class PermutohedralLatticeGPU{
public:
    int n; //number of pixels/voxels etc..
    int * canonical;
    T * scaleFactor;
    MatrixEntry<T>* matrix;
    HashTableGPU<T, pd, vd> hashTable;
    cudaStream_t stream;

    T * newValues; // auxiliary array for blur stage
    //number of blocks and threads per block
    //dim3 blocks;
    //dim3 blockSize;
    //dim3 cleanBlocks;
    //unsigned int cleanBlockSize;

    void init_canonical(){
        int hostCanonical[(pd + 1) * (pd + 1)];
        //auto canonical = new int[(pd + 1) * (pd + 1)];
        // compute the coordinates of the canonical simplex, in which
        // the difference between a contained point and the zero
        // remainder vertex is always in ascending order. (See pg.4 of paper.)
        for (int i = 0; i <= pd; i++) {
            for (int j = 0; j <= pd - i; j++)
                hostCanonical[i * (pd + 1) + j] = i;
            for (int j = pd - i + 1; j <= pd; j++)
                hostCanonical[i * (pd + 1) + j] = i - (pd + 1);
        }
        size_t size =  ((pd + 1) * (pd + 1))*sizeof(int);
        cudaMalloc((void**)&(canonical), size);
        cudaMemcpy(canonical, hostCanonical, size, cudaMemcpyHostToDevice);
    }


    void init_scaleFactor(){
        T hostScaleFactor[pd];
        T inv_std_dev = (pd + 1) * sqrt(2.0f / 3);
        for (int i = 0; i < pd; i++) {
            hostScaleFactor[i] = 1.0f / (sqrt((T) (i + 1) * (i + 2))) * inv_std_dev;
        }
        size_t size =  pd*sizeof(T);
        cudaMalloc((void**)&(scaleFactor), size);
        cudaMemcpy(scaleFactor, hostScaleFactor, size, cudaMemcpyHostToDevice);
    }

    void init_matrix(){
        cudaMalloc((void**)&(matrix), n * (pd + 1) * sizeof(MatrixEntry<T>));
    }

    void init_newValues(){
        cudaMalloc((void **) &(newValues), n * (pd + 1) * vd * sizeof(T));
        cudaMemset((void *) newValues, 0, n * (pd + 1) * vd * sizeof(T));
    }


    PermutohedralLatticeGPU(int n_, cudaStream_t stream_=0):
            n(n_),
            canonical(nullptr),
            scaleFactor(nullptr),
            matrix(nullptr),
            newValues(nullptr),
            hashTable(HashTableGPU<T, pd, vd>(n * (pd + 1))),
            stream(stream_){

        if (n >= 65535 * BLOCK_SIZE) {
            printf("Not enough GPU memory (on x axis, you can change the code to use other grid dims)\n");
            //this should crash the program
        }

        // initialize device memory
        init_canonical();
        init_scaleFactor();
        init_matrix();
        init_newValues();
        //
        //blocks = dim3((n - 1) / BLOCK_SIZE + 1, 1, 1);
        //blockSize = dim3(BLOCK_SIZE, 1, 1);
        //cleanBlockSize = 32;
        //cleanBlocks = dim3((n - 1) / cleanBlockSize + 1, 2 * (pd + 1), 1);
    }

    ~PermutohedralLatticeGPU(){
        cudaFree(canonical);
        cudaFree(scaleFactor);
        cudaFree(matrix);
        cudaFree(newValues);
    }


    // values and position must already be device pointers
    void filter(T* output, const T* inputs, const T*  positions, bool reverse){

        dim3 blocks((n - 1) / BLOCK_SIZE + 1, 1, 1);
        dim3 blockSize(BLOCK_SIZE, 1, 1);
        int cleanBlockSize = 32;
        dim3 cleanBlocks((n - 1) / cleanBlockSize + 1, 2 * (pd + 1), 1);

        createLattice<T, pd, vd> <<<blocks, blockSize, 0, stream>>>(n, positions, scaleFactor, canonical, matrix, hashTable);
        printf("Create Lattice: %s\n", cudaGetErrorString(cudaGetLastError()));

        cleanHashTable<T, pd, vd> <<<cleanBlocks, cleanBlockSize, 0, stream>>>(2 * n * (pd + 1), hashTable);
        printf("Clean Hash Table: %s\n", cudaGetErrorString(cudaGetLastError()));

        blocks.y = pd + 1;
        splatCache<T, pd, vd><<<blocks, blockSize, 0, stream>>>(n, inputs, matrix, hashTable);
        printf("Splat: %s\n", cudaGetErrorString(cudaGetLastError()));

        for (int remainder=reverse?pd:0; remainder >= 0 && remainder <= pd; reverse?remainder--:remainder++) {
            blur<T, pd, vd><<<cleanBlocks, cleanBlockSize, 0, stream>>>(n * (pd + 1), newValues, matrix, remainder, hashTable);
            printf("Blur %d: %s\n", remainder, cudaGetErrorString(cudaGetLastError()));
            std::swap(hashTable.values, newValues);
        }
        blockSize.y = 1;
        slice<T, pd, vd><<<blocks, blockSize, 0, stream>>>(n, output, matrix, hashTable);
        printf("Slice: %s\n", cudaGetErrorString(cudaGetLastError()));
    }

};


template<typename T, int pd, int vd>
void filter(T *output, const T *input, const T *positions, int n, bool reverse) {
    auto lattice = PermutohedralLatticeGPU<T, pd, vd>(n);
    lattice.filter(output, input, positions, reverse);

}

template<typename T>
__global__ static void compute_kernel(const T * reference,
                                      T * positions,
                                      int num_super_pixels,
                                      int reference_channels,
                                      int n_sdims,
                                      const int *sdims,
                                      T spatial_std,
                                      T feature_std){

    const int idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx >= num_super_pixels)
        return;

    int num_dims = n_sdims + reference_channels;
    int divisor = 1;
    for(int sdim = n_sdims - 1; sdim >= 0; sdim--){
        positions[num_dims * idx + sdim] = ((idx / divisor) % sdims[sdim]) / spatial_std;
        divisor *= sdims[sdim];
    }

    for(int channel = 0; channel < reference_channels; channel++){
        positions[num_dims * idx + n_sdims + channel] = reference[idx * reference_channels + channel] / feature_std;
    }

}



#endif //PERMUTOHEDRAL_CU

