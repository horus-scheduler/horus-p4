#ifndef __HEADER_P4__
#define __HEADER_P4__ 1

#define NUM_SW_PORTS   48
#define NUM_LEAF_US    24
#define NUM_LEAF_DS    24
#define NUM_SPINE_DS   24
#define NUM_SPINE_US   24

#define PKT_TYPE_NEW_TASK 0
#define PKT_TYPE_NEW_TASK_RANDOM 1
#define PKT_TYPE_TASK_DONE 2
#define PKT_TYPE_TASK_DONE_IDLE 3
#define PKT_TYPE_QUEUE_REMOVE 4
#define PKT_TYPE_SCAN_QUEUE_SIGNAL 5
#define PKT_TYPE_IDLE_SIGNAL 6
#define PKT_TYPE_QUEUE_SIGNAL 7
#define PKT_TYPE_PROBE_IDLE_QUEUE 8
#define PKT_TYPE_PROBE_IDLE_RESPONSE 9
#define PKT_TYPE_IDLE_REMOVE 10

#define HDR_PKT_TYPE_SIZE 8
#define HDR_CLUSTER_ID_SIZE 16
#define HDR_LOCAL_CLUSTER_ID_SIZE 8
#define HDR_SRC_ID_SIZE 16
#define HDR_QUEUE_LEN_SIZE 9
#define HDR_SEQ_NUM_SIZE 16
#define HDR_FALCON_RAND_GROUP_SIZE 8
#define HDR_FALCON_DST_SIZE 8

#define QUEUE_LEN_FIXED_POINT_SIZE 8

// These are local per-rack values as ToR does not care about other racks
#define MAX_IDLE_WORKERS_PER_CLUSTER 16 
#define MAX_WORKERS_PER_CLUSTER 16

header falcon_h {
    bit<HDR_PKT_TYPE_SIZE> pkt_type;
    bit<HDR_CLUSTER_ID_SIZE> cluster_id;
    bit<HDR_LOCAL_CLUSTER_ID_SIZE> local_cluster_id;
    bit<16> src_id;                 // workerID for ToRs. ToRID for spines.
    bit<16> dst_id;
    bit<8> qlen;                    // Also used for reporting length of idle list (from spine sw to leaf sw)
    bit<HDR_SEQ_NUM_SIZE> seq_num;   
}

struct falcon_header_t {
    ethernet_h ethernet;
    ipv4_h ipv4;
    udp_h udp;
    falcon_h falcon;
}

struct falcon_metadata_t {
    bit<1> switch_type;
    bit<HDR_SRC_ID_SIZE> random_downstream_id_1;
    bit<HDR_SRC_ID_SIZE> random_downstream_id_2;
    bit<HDR_SRC_ID_SIZE> selected_downstream_id;
    bit<HDR_SRC_ID_SIZE> cluster_num_valid_ds; // Holds number of downstream components (workers/tor scheds) in current cluster
    bit<HDR_SRC_ID_SIZE> cluster_num_avail_queue;
    bit<HDR_SRC_ID_SIZE> idle_downstream_id;
    bit<8> qlen_curr;
    bit<8> last_idle_list_len;
    bit<HDR_SRC_ID_SIZE> last_idle_probe_id;
    bit<HDR_SRC_ID_SIZE> shortest_idle_queue_id;
    bit<HDR_SRC_ID_SIZE> linked_sq_id;
    bit<HDR_SRC_ID_SIZE> linked_iq_id;
    bit<8> qlen_agg;
    bit<8> qlen_rand_1;
    bit<8> qlen_rand_2;
    bit<8> min_qlen;
    bit<HDR_FALCON_RAND_GROUP_SIZE> rand_probe_group;
    bit<HDR_FALCON_DST_SIZE> falcon_dst;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> queue_len_unit; // (1/num_worekrs) for each vcluster
    bit<HDR_SRC_ID_SIZE> cluster_idle_count;
    bit<16> idle_worker_index;
    bit<16> worker_index;
    bit<16> cluster_worker_start_idx;
}


#endif // __HEADER_P4__
