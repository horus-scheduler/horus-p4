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
#define HDR_QUEUE_LEN_SIZE 8
#define HDR_SEQ_NUM_SIZE 16
#define HDR_FALCON_RAND_GROUP_SIZE 8
#define HDR_FALCON_DST_SIZE 8

#define QUEUE_LEN_FIXED_POINT_SIZE 8


#define MAX_VCLUSTERS 32
#define MAX_WORKERS_PER_CLUSTER 16
#define MAX_LEAFS_PER_CLUSTER 16

#define MAX_WORKERS_IN_RACK 1024 
#define MAX_LEAFS 1024

// This defines the maximum queue length signals (for each vcluster) that a single spine would maintain (MAX_LEAFS/L_VALUE)
#define MAX_LINKED_LEAFS 64 

/* 
 This limits the number of multicast groups available for selecting spines. Put log (base 2) of max groups here.
 Max number of groups will be 2^MAX_BITS_UPSTREAM_MCAST_GROUP
*/
#define MAX_BITS_UPSTREAM_MCAST_GROUP 4

#define MIRROR_TYPE_WORKER_RESPONSE 1
#define MIRROR_TYPE_NEW_TASK 2

#define RESUBMIT_TYPE_NEW_TASK 1

typedef bit<8> queue_len_t;
typedef bit<9> port_id_t;
typedef bit<16> worker_id_t;
typedef bit<16> leaf_id_t;
typedef bit<16> switch_id_t;
typedef bit<QUEUE_LEN_FIXED_POINT_SIZE> len_fixed_point_t;

header empty_t {
}

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

struct eg_metadata_t {

}

header resub_hdr_t {
    bit<16> udpate_ds_index; // This shows the index in qlen arrays to be updated
    //bit<16> dst_id; // This shows the wid to put in packet hdr (and forward based on this)
}

struct falcon_metadata_t {
    
    bit<HDR_SRC_ID_SIZE> linked_sq_id;
    bit<HDR_SRC_ID_SIZE> linked_iq_id;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> queue_len_unit; // (1/num_worekrs) for each vcluster
    bit<HDR_SRC_ID_SIZE> cluster_idle_count;
    bit<16> idle_ds_index;
    bit<16> worker_index;
    bit<16> cluster_ds_start_idx;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> aggregate_queue_len;
    MulticastGroupId_t rand_probe_group;
    bit<16> cluster_num_valid_ds;
    bit<16> cluster_num_valid_queue_signals;
    bit<16> random_downstream_id_1;
    bit<16> random_downstream_id_2;
    bit<16> random_ds_index_1;
    bit<16> random_ds_index_2;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> worker_qlen_1;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> worker_qlen_2;

    bit<QUEUE_LEN_FIXED_POINT_SIZE> random_ds_qlen_1;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> random_ds_qlen_2;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> selected_ds_qlen;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> not_selected_ds_qlen;
    
    bit<16> idle_ds_id;
    bit<8> selected_spine_iq_len;
    bit<8> last_iq_len;
	bit<16> last_probed_id;
	bit<16> spine_to_link_iq;
	
	bit<16> cluster_max_linked_leafs;
	bit<16> mirror_dst_id; // Usage similar to hdr.dst_id but this is for mirroring
	resub_hdr_t task_resub_hdr;
}


#endif // __HEADER_P4__