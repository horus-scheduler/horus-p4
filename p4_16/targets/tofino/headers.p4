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
#define PKT_TYPE_QUEUE_SIGNAL_INIT 11

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
// This is the total length of array (shared between vclusters) for tracking leaf queue lengths
#define MAX_TOTAL_LEAFS  8192 

#define ARRAY_SIZE 573500

/* 
 This limits the number of multicast groups available for selecting spines. Put log (base 2) of max groups here.
 Max number of groups will be 2^MAX_BITS_UPSTREAM_MCAST_GROUP
*/
#define MAX_BITS_UPSTREAM_MCAST_GROUP 4

#define MIRROR_TYPE_WORKER_RESPONSE 1
#define MIRROR_TYPE_NEW_TASK 2

#define RESUBMIT_TYPE_NEW_TASK 1
#define RESUBMIT_TYPE_IDLE_REMOVE 2

const bit<8> INVALID_VALUE_8bit = 8w0x7F;
const bit<16> INVALID_VALUE_16bit = 16w0x7FFF;

typedef bit<HDR_QUEUE_LEN_SIZE> queue_len_t;
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
    bit<HDR_QUEUE_LEN_SIZE> qlen;                    // Also used for reporting length of idle list (from spine sw to leaf sw)
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

// We use the same resub header format for removal to avoid using additional parser resources
header task_resub_hdr_t {
    bit<16> ds_index_1; // This shows the index to be updated
    bit<16> ds_index_2; // This shows the index to be updated
    bit<HDR_QUEUE_LEN_SIZE> qlen_1;
    bit<HDR_QUEUE_LEN_SIZE> qlen_2;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> qlen_unit_1;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> qlen_unit_2;
}

header remove_resub_hdr_t {
    bit<16> removed_position; // This shows the index to be updated in idle list
    bit<16> list_top_leaf; // This shows the value to be written in the previously removed position
}

struct falcon_metadata_t {
    bit<HDR_SRC_ID_SIZE> linked_sq_id;
    bit<HDR_SRC_ID_SIZE> linked_iq_id;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> queue_len_unit; // (1/num_worekrs) for each vcluster
    bit<QUEUE_LEN_FIXED_POINT_SIZE> queue_len_unit_sample_1; // (1/num_worekrs) for each vcluster
    bit<QUEUE_LEN_FIXED_POINT_SIZE> queue_len_unit_sample_2; // (1/num_worekrs) for each vcluster
    bit<8> cluster_idle_count;
    bit<16> idle_ds_index;
    bit<16> worker_index;
    bit<16> cluster_ds_start_idx;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> aggregate_queue_len;
    MulticastGroupId_t rand_probe_group;
    bit<16> cluster_num_valid_ds;
    bit<16> cluster_num_valid_us;
    bit<16> cluster_num_valid_queue_signals;
    bit<16> random_id_1;
    bit<16> random_id_2;
    bit<16> random_ds_index_1;
    bit<16> random_ds_index_2;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> worker_qlen_1;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> worker_qlen_2;

    bit<QUEUE_LEN_FIXED_POINT_SIZE> random_ds_qlen_1;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> random_ds_qlen_2;

    bit<QUEUE_LEN_FIXED_POINT_SIZE> selected_correct_qlen;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> not_selected_correct_qlen;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> min_correct_qlen;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> selected_ds_qlen;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> not_selected_ds_qlen;
    bit<QUEUE_LEN_FIXED_POINT_SIZE> queue_len_diff;

    bit<8> deferred_qlen_1;
    bit<16> cluster_absolute_leaf_index;
    bit<16> idle_ds_id;
    bit<8> selected_spine_iq_len;
    bit<8> last_iq_len;
	bit<16> last_probed_id;
	bit<16> spine_to_link_iq;
	bit<16> received_src_id;
	bit<16> num_additional_signal_needed;
	bit<16> cluster_max_linked_leafs;
	bit<16> mirror_dst_id; // Usage similar to hdr.dst_id but this is for mirroring
	bit<16> lid_ds_index;
	bit<16> idle_id_to_write;
	task_resub_hdr_t task_resub_hdr;
	remove_resub_hdr_t remove_resub_hdr;
	bit<8> idle_len_8bit;

}


#endif // __HEADER_P4__