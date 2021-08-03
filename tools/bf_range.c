/* 
 * bf_range.c
 *
 * This program converts an arbitrary range into a set of non-intersecting
 * ternary entries, suitable to be installed into a TCAM.
 * The worst number of entries is: 2*floor(log2(max-min))
 *  
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include <math.h>


unsigned hex_width;
unsigned dec_width;

void calculate_widths(uint64_t min, uint64_t max)
{
    double dmax;
    if (min <= max) {
        dmax = max;
    } else {
        dmax = min;
    }

    hex_width = (((unsigned)log2(dmax)) + 4) / 4;
    dec_width = log10(dmax) + 1;
}

void
print_solution(uint64_t min, uint64_t max) {
    printf("0x%0*"PRIx64" .. 0x%0*"PRIx64
           "\t[%*"PRIu64", %*"PRIu64"]\t%*"PRIu64"\n", 
           hex_width, min, hex_width, max,
           dec_width, min, dec_width, max,
           dec_width, max - min + 1);
}

void
bf_range(uint64_t min, uint64_t max)
{
    int i, j, k, nybble;
    uint64_t mask;
    uint64_t clean_min, stride;
    
    if (min <= max) {
        /* 
         * Find the longest range, that doesn't "overshoot" max.
         * The longest range (stride) covered by a particular mask is h*16^N 
         * values (h=1..16). i.e. min..min+2^N-1, but to use such a stride,
         * min must have N*4 right bits set to 0.
         * 
         * So, we will find the longest mask that we can use with the given 
         * value of min (basically by finding the lowest bit that is set).
         * 
         * Then we'll use this or more narrow masks till we either find 
         * the one to fit or we find the first one that "undershoots" 
         * the max and then we split the range.
         */
        for (i = 0; i < 64; i+=4) {
            mask = 0xFULL << i;
            if ((min & mask) || ((mask | ((1ULL << i) - 1)) > max)) break;
        }

        for (j = i; j >= 0; j-=4) {
            nybble = (min >> j) & 0xF;
            clean_min = min & ~(0xFULL << j);
            for (k = 0xF; k >= nybble ; k--) {
                stride = (((uint64_t)k + 1) << j) - 1; 
                if (clean_min + stride == max) {
                    print_solution(min, max);
                    return;
                } else if (clean_min + stride < max) {
                    bf_range(min, clean_min + stride);
                    bf_range(clean_min + stride + 1, max);
                    return;
                }
            }
        }        
    } else {
        bf_range(max, min);
    }
}

int
main(int argc, char *argv[])
{
    uint64_t min, max;

    if (argc != 3) {
        fprintf(stderr, 
                "Usage: \n"
                "\t%s: <min> <max>\n",
                argv[0]);
        return(1);
    }

    sscanf(argv[1], "%"SCNu64, &min);
    sscanf(argv[2], "%"SCNu64, &max);
    
    calculate_widths(min, max);
    bf_range(min, max);

    return (0);
}
