/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#ifndef _HOPSCOTCH_H_
#define _HOPSCOTCH_H_

struct hopscotch_table {
    uword_t*   keys;
    unsigned*  hops;
    unsigned*  values;
    unsigned   mask;
    int  hop_range;
    int  count;
    int  threshold;  // max count before sizing up
    int  prev_size;  // in cells, as specified to hopscotch_create()
    int  mem_size;   // in bytes, for zero-filling when done using
    // Statistics
    struct { int n_seeks, n_probes; } hit, miss;
    char resized;    // set to 1 if sized up since last reset
    char rehashing;  // set to 1 during rehash
};

void hopscotch_init();
void hopscotch_create(struct hopscotch_table*,boolean,int,char);
int hopscotch_put(struct hopscotch_table*,uword_t,unsigned);
int hopscotch_get(struct hopscotch_table*,uword_t);
int hopscotch_containsp(struct hopscotch_table*,uword_t);
void hopscotch_reset(struct hopscotch_table*);
void hopscotch_log_stats(struct hopscotch_table*);

/* This confuses me every time I look at it, so here's an example-
 * Suppose (unrealistically) that a table has a hop range of 4,
 * and 16 logical bins. The largest logical bin index (= the table mask)
 * is 15, and there are 3 (not 4) more cells at the end.
 * So the largest physical index in which you can probe without
 * overrunning the key array is (mask + range - 1).
 * i.e. the neighborhood of logical cell index 15 is {15,16,17,18}.
 * The total count of physical key cells is (mask + 1) + (range - 1)
 * where (mask + 1) is the logical bin count.
 */
#define hopscotch_max_key_index(table) ((table).mask+(table).hop_range-1)

#define for_each_hopscotch_key(indexvar, keyvar, tablevar) \
  for(indexvar=hopscotch_max_key_index(tablevar) ; indexvar >= 0 ; --indexvar) \
    if ((keyvar=tablevar.keys[indexvar])!=0)

#endif
