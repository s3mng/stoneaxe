#include <metal_stdlib>
using namespace metal;

constant uint K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};
inline uint rr(uint v, uint n) { return (v >> n) | (v << (32-n)); }
inline uint swap32(uint v) { return ((v & 255) << 24) | ((v & 0xff00) << 8) | ((v >> 8) & 0xff00) | (v >> 24); }
inline void initial(thread uint *h) {
    h[0]=0x6a09e667; h[1]=0xbb67ae85; h[2]=0x3c6ef372; h[3]=0xa54ff53a;
    h[4]=0x510e527f; h[5]=0x9b05688c; h[6]=0x1f83d9ab; h[7]=0x5be0cd19;
}
inline void compress(thread uint *h, thread uint *w) {
    for(uint i=16;i<64;i++) {
        uint a=w[i-15], b=w[i-2];
        w[i]=w[i-16]+(rr(a,7)^rr(a,18)^(a>>3))+w[i-7]+(rr(b,17)^rr(b,19)^(b>>10));
    }
    uint a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],z=h[7];
    for(uint i=0;i<64;i++) {
        uint t=z+(rr(e,6)^rr(e,11)^rr(e,25))+((e&f)^(~e&g))+K[i]+w[i];
        uint u=(rr(a,2)^rr(a,13)^rr(a,22))+((a&b)^(a&c)^(b&c));
        z=g;g=f;f=e;e=d+t;d=c;c=b;b=a;a=t+u;
    }
    h[0]+=a;h[1]+=b;h[2]+=c;h[3]+=d;h[4]+=e;h[5]+=f;h[6]+=g;h[7]+=z;
}
// input: 20 big-endian header words, 8 target words, starting nonce, count.
// output: atomic share count, up to 64 nonces, then one best nonce per workgroup.
kernel void mine(const device uint *input [[buffer(0)]], device uint *output [[buffer(1)]],
                 uint gid [[thread_position_in_grid]], uint tid [[thread_index_in_threadgroup]],
                 uint group [[threadgroup_position_in_grid]]) {
    threadgroup uint highs[256], lows[256], nonces[256];
    uint nonce=input[28]+gid;
    uint h[8], w[64]; initial(h);
    for(uint i=0;i<16;i++) w[i]=input[i];
    compress(h,w);
    for(uint i=0;i<16;i++) w[i]=0;
    w[0]=input[16];w[1]=input[17];w[2]=input[18];w[3]=swap32(nonce);w[4]=0x80000000;w[15]=640;
    compress(h,w);
    for(uint i=0;i<8;i++) w[i]=h[i];
    for(uint i=8;i<16;i++) w[i]=0;
    w[8]=0x80000000;w[15]=256;
    initial(h);compress(h,w);
    bool valid=true;
    for(uint i=0;i<8;i++) {
        uint v=swap32(h[7-i]);
        if(v<input[20+i]) break;
        if(v>input[20+i]) { valid=false; break; }
    }
    if(valid) {
        uint slot=atomic_fetch_add_explicit((device atomic_uint*)output,1u,memory_order_relaxed);
        if(slot<64) output[1+slot]=nonce;
    }
    highs[tid]=swap32(h[7]);lows[tid]=swap32(h[6]);nonces[tid]=nonce;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint stride=128;stride>0;stride>>=1) {
        if(tid<stride) {
            uint j=tid+stride;
            if(highs[j]<highs[tid] || (highs[j]==highs[tid] && lows[j]<lows[tid])) {
                highs[tid]=highs[j];lows[tid]=lows[j];nonces[tid]=nonces[j];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if(tid==0) output[65+group]=nonces[0];
}
