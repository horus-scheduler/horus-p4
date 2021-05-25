#include <core.p4>
#include <tna.p4>

#include "common/headers.p4"
#include "common/util.p4"
#include "headers.p4"
#include "parser.p4"

#define MAX_VCLUSTERS 32
#define MAX_WORKERS_PER_CLUSTER 16
/* 
 This limits the number of multicast groups available for selecting spines. Put log (base 2) of max groups here.
 Max number of groups will be 2^MAX_BITS_UPSTREAM_MCAST_GROUP
*/
#define MAX_BITS_UPSTREAM_MCAST_GROUP 4

#define MIRROR_TYPE_WORKER_RESPONSE 1
#define MIRROR_TYPE_NEW_TASK 2

typedef bit<8> queue_len_t;
typedef bit<9> port_id_t;
typedef bit<16> worker_id_t;
typedef bit<16> switch_id_t;
typedef bit<QUEUE_LEN_FIXED_POINT_SIZE> len_fixed_point_t;

header empty_t {
}

/*
 * Notes:
 *  An action can be called directly without a table (from apply{} block)
 *  Here multiple calls to action from the apply{} block is allowed (e.g in different if-else branches)
 *  Limitations: 
 *    If multiple operations (simple arith +,-,...) done in a single action results in error. "Action Require multiple stages for 
 *    a single action. We currently support only single stage actions."
 * 
 *    Multiple operations in a single branch of apply{} block not allowed. The operations must be done in seperate actions (That 
 *     translates to parallel ALU blocks in hardware?)
 *    Index of reg (passed to .execute()) can not be computed in the same block of apply{}. But index can be computed in an action. 
 *    
 *   (As far as we know) Multiple accesses to the same register is not allowed. To overcome the restriction define the RegActions in a way that we can handle the different conditions inside them.
 *   
 *   Random generator only accepts constant upper bound. This causes problem for when we have different number of workers in the rack 
 *    and to select from them we need the random number to be in that specific range. 
 *
 *   Only one RegisterAction may be executed per packet for a given Register. This is a significant limitation for our algorithm.
 *   Switch can not read n random registers and then increment the selected worker's register after comparison. We need to rely on worker to update the qlen later. 
 *   
 *   Comparing two metadeta feilds (with < >) in apply{} blcok resulted in error. (Too complex). Only can use == on two meta feilds!
*/

control LeafIngress(
        inout falcon_header_t hdr,
        inout falcon_metadata_t falcon_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md) {

            /* *** Register definitions *** */ 
            // TODO: Check Reg definition is _ correct?
            // idle list should be allocated to store MAX_VCLUSTER_RACK * MAX_IDLES_RACK
            Register<worker_id_t, _>(1024) idle_list;
            RegisterAction<bit<16>, _, bit<16>>(idle_list) add_to_idle_list = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    value = hdr.falcon.src_id;
                    rv = value;
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(idle_list) read_idle_list = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value;
                }
            };
            Register<bit<16>, _>(MAX_VCLUSTERS) idle_count; // Stores idle count for each vcluster
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value; // Retruns val    
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_and_inc_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value; // Retruns val before modificaiton
                    if (value < 0xFF) { // 0xFF reserved for "NO IDLE"
                        value = value + 1;
                    }
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_and_dec_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    if (value > 0) { 
                        rv = value;
                        value = value - 1;
                    }
                }
            };
            

            Register<queue_len_t, _>(1024) queue_len_1; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_1) inc_queue_len_list_1 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = value + 1;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_1) read_queue_len_list_1 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };


            Register<queue_len_t, _>(1024) queue_len_2; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_2) inc_queue_len_list_2 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = value + 1;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_2) read_queue_len_list_2 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };
            
            Register<queue_len_t, _>(1024) queue_len_3; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_3) write_queue_len_list_3 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_3) read_queue_len_list_3 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_4; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_4) write_queue_len_list_4 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_4) read_queue_len_list_4 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_5; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_5) write_queue_len_list_5 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_5) read_queue_len_list_5 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_6; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_6) write_queue_len_list_6 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_6) read_queue_len_list_6 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_7; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_7) write_queue_len_list_7 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_7) read_queue_len_list_7 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_8; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_8) write_queue_len_list_8 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_8) read_queue_len_list_8 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_9; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_9) write_queue_len_list_9 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_9) read_queue_len_list_9 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_10; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_10) write_queue_len_list_10 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_10) read_queue_len_list_10 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_11; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_11) write_queue_len_list_11 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_11) read_queue_len_list_11 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_12; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_12) write_queue_len_list_12 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_12) read_queue_len_list_12 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_13; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_13) write_queue_len_list_13 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_13) read_queue_len_list_13 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_14; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_14) write_queue_len_list_14 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_14) read_queue_len_list_14 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_15; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_15) write_queue_len_list_15 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_15) read_queue_len_list_15 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(1024) queue_len_16; // List of queue lens for all vclusters
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_16) write_queue_len_list_16 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = hdr.falcon.qlen;
                    rv = value;
                }
            };
            RegisterAction<queue_len_t, _, queue_len_t>(queue_len_16) read_queue_len_list_16 = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(MAX_VCLUSTERS) aggregate_queue_len_list; // One for each vcluster
            RegisterAction<bit<8>, _, bit<8>>(aggregate_queue_len_list) update_read_aggregate_queue_len = {
                void apply(inout bit<8> value, out bit<8> rv) {
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        value = value + falcon_md.queue_len_unit;
                    } else {
                        value = value - falcon_md.queue_len_unit;
                    }
                    rv = value;
                }
            };
            RegisterAction<bit<8>, _, bit<8>>(aggregate_queue_len_list) read_aggregate_queue_len = {
                void apply(inout bit<8> value, out bit<8> rv) {
                    rv = value;
                }
            };
            
            Register<switch_id_t, _>(MAX_VCLUSTERS) linked_iq_sched; // Spine that ToR has sent last IdleSignal (1 for each vcluster).
            RegisterAction<bit<16>, _, bit<16>>(linked_iq_sched) read_reset_linked_iq  = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value;
                    value = 0xFFFF;
                }
            };
            

            Register<switch_id_t, _>(MAX_VCLUSTERS) linked_sq_sched; // Spine that ToR has sent last QueueSignal (1 for each vcluster).
            RegisterAction<bit<16>, _, bit<16>>(linked_sq_sched) read_update_linked_sq  = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value;
                    if (value == 0xFFFF && hdr.falcon.pkt_type == PKT_TYPE_SCAN_QUEUE_SIGNAL) { // Not linked before and new SCAN request arrived
                        value = hdr.falcon.src_id;
                    }
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(linked_sq_sched) write_linked_sq  = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(linked_sq_sched) remove_linked_sq  = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    value = 0xFFFF;
                    rv = value;
                }
            };
            // Below are registers to hold state in middle of probing Idle list proceess. 
            // So we can compare them when second switch responds.
            Register<queue_len_t, _>(MAX_VCLUSTERS) spine_iq_len_1; // Length of Idle list for first probed spine (1 for each vcluster).
            RegisterAction<queue_len_t, _, queue_len_t>(spine_iq_len_1) read_update_spine_iq_len_1  = {
                void apply(inout queue_len_t value, out queue_len_t rv) {
                    rv = value;
                    if (value == 0xFF) { // Value==INVALID, So this is the first probe and we store the data
                        value = hdr.falcon.qlen;
                    } else { // Value found so this is the second probe and we load the data
                        value = 0xFF;
                    }
                }
            };
            Register<switch_id_t, _>(MAX_VCLUSTERS) spine_probed_id; // ID of the first probed spine (1 for each vcluster)
            RegisterAction<switch_id_t, _, switch_id_t>(spine_probed_id) read_update_spine_probed_id  = {
                void apply(inout switch_id_t value, out switch_id_t rv) {
                    rv = value;
                    if (value == 0xFFFF) { // Value==INVALID, So this is the first probe and we store the data.
                        value = hdr.falcon.src_id;
                    } else { // Value found so this is the second probe and we load the data
                        value = 0xFFFF;
                    }
                }
            };
            Random<bit<MAX_BITS_UPSTREAM_MCAST_GROUP>>() random_probe_group;
            /* 
              As a workaround since we can't select the random range in runtime. 
              We get() from one of these variables depending on number of workers in rack.
              TODO: This limits the num workers to be pow of 2. Also, is this biased random?
              TODO: Multiple .get() calls result in different ranodm numbers? Or should we make another Random extern for that purpose?
            */
            Random<bit<16>>() random_worker_id_16;
            // Random<bit<8>>() random_worker_id_8;
            // Random<bit<4>>() random_worker_id_4;
            // Random<bit<2>>() random_worker_id_2;
            // Random<bit<1>>() random_worker_id_1;

            // Stage X
            action get_worker_start_idx () {
                falcon_md.cluster_worker_start_idx = (bit <16>) (hdr.falcon.cluster_id * MAX_WORKERS_PER_CLUSTER);
            }

            // Calculates the index of next idle worker in idle_list array.
            action get_idle_index () {
                falcon_md.idle_worker_index = falcon_md.cluster_worker_start_idx + (bit <16>) falcon_md.cluster_idle_count;
            }

            action get_curr_idle_index() {
                falcon_md.idle_worker_index = falcon_md.idle_worker_index -1;
            }

            // action get_worker_index () {
            //     falcon_md.worker_index = (bit<16>) hdr.falcon.src_id + falcon_md.cluster_worker_start_idx;
            // }

            action _drop() {
                ig_intr_dprsr_md.drop_ctl = 0x1; // Drop packet.
            }

            action act_set_queue_len_unit(len_fixed_point_t cluster_unit){
                falcon_md.queue_len_unit = cluster_unit;
            }
            table set_queue_len_unit {
                key = {
                    hdr.falcon.local_cluster_id: exact;
                }
                actions = {
                    act_set_queue_len_unit;
                    _drop;
                }
                    size = HDR_CLUSTER_ID_SIZE;
                    default_action = _drop;
            }

            action gen_random_probe_group() { // For probing two out of n spine schedulers
                ig_intr_tm_md.mcast_grp_a = (MulticastGroupId_t) 1; // Assume all use a single grp level 1
                /* 
                  Limitation: Casting the output of Random instance and assiging it directly to mcast_grp_b did not work. 
                  Had to assign it to a 16 bit meta field and then assign to mcast_group. 
                */
                // Different out ports for level 2 randomly generated
                // Here we use the same random 16 bit number generated for downstream ID to save resources
                ig_intr_tm_md.mcast_grp_b = falcon_md.random_downstream_id_1; 
            }
        
            // action set_mirror_type_worker_response() {
            //     ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_WORKER_RESPONSE;
            // }

            action act_forward_falcon(PortId_t port) {
                ig_intr_tm_md.ucast_egress_port = port;
            }
            table forward_falcon_switch_dst {
                key = {
                    hdr.falcon.dst_id: exact;
                }
                actions = {
                    act_forward_falcon;
                    NoAction;
                }
                size = HDR_SRC_ID_SIZE;
                default_action = NoAction;
            }

            action act_get_cluster_num_valid_ds(bit<16> num_ds_elements) {
                falcon_md.cluster_num_valid_ds = num_ds_elements;
            }
            table get_cluster_num_valid_ds {
                key = {
                    hdr.falcon.cluster_id : exact;
                }
                actions = {
                    act_get_cluster_num_valid_ds;
                    NoAction;
                }
                size = HDR_CLUSTER_ID_SIZE;
                default_action = NoAction;
            }

            action gen_random_workers_16() {
                falcon_md.random_downstream_id_1 = (bit<16>) random_worker_id_16.get();
                falcon_md.random_downstream_id_2 = (bit<16>) random_worker_id_16.get();
            }
            
            action adjust_random_worker_range_8() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 8;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 8;
            }

            action adjust_random_worker_range_4() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 12;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 12;
            }

            action adjust_random_worker_range_2() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 14;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 14;
            }

            action adjust_random_worker_range_1() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 15;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 15;
            }
            table adjust_random_range { // Reduce the random generated number (16 bit) based on number of workers in rack
                key = {
                    falcon_md.cluster_num_valid_ds: exact; 
                }
                actions = {
                    adjust_random_worker_range_8(); // == 8
                    adjust_random_worker_range_4(); // == 4
                    adjust_random_worker_range_2(); // == 2
                    adjust_random_worker_range_1(); // == 1
                    NoAction; // == 16
                }
                size = 16;
                default_action = NoAction;
            }

            action offset_random_ids() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 + falcon_md.cluster_worker_start_idx;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 + falcon_md.cluster_worker_start_idx;
            }

            action act_random1_qlen1() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_1;
            }
            action act_random1_qlen2() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_2;
            }
            table assign_qlen_random1 {
                key = {
                    falcon_md.random_downstream_id_1 : exact;
                }
                actions = {
                    act_random1_qlen1;
                    act_random1_qlen2;
                    NoAction;
                }
                size = 16;
                default_action = NoAction;
            }
            action act_random2_qlen1() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_1;
            }
            action act_random2_qlen2() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_2;
            }
            table assign_qlen_random2 {
                key = {
                    falcon_md.random_downstream_id_2 : exact;
                }
                actions = {
                    act_random2_qlen1;
                    act_random2_qlen2;
                    NoAction;
                }
                size = 16;
                default_action = NoAction;
            }
            action compare_queue_len() {
                falcon_md.selected_worker_qlen = min(falcon_md.random_worker_qlen_1, falcon_md.random_worker_qlen_2);
            }

            action compare_spine_iq_len() {
                falcon_md.selected_spine_iq_len = min(falcon_md.last_iq_len, hdr.falcon.qlen);
            }

            action convert_pkt_to_sq_signal() {
                hdr.falcon.pkt_type = PKT_TYPE_QUEUE_SIGNAL; // This should be set in last stage because effects other stages (if conditions)
                hdr.falcon.qlen = falcon_md.aggregate_queue_len;
            }
            

            apply {
                if (hdr.falcon.isValid()) {  // Falcon packet

                    /**Stage 0
                     * get_worker_start_idx
                     * queue_len_unit
                     Registers:
                     * idle_count
                     * linked_sq_sched
                    */
                    get_worker_start_idx(); // Get start index of workers for this vcluster
                    set_queue_len_unit.apply();
                    if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) {
                            // @st st_idle_count = 0
                        falcon_md.cluster_idle_count = read_and_inc_idle_count.execute(hdr.falcon.cluster_id);
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        falcon_md.cluster_idle_count = read_and_dec_idle_count.execute(hdr.falcon.cluster_id); // Read last idle count for vcluster
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_RESPONSE) {
                        falcon_md.cluster_idle_count = read_idle_count.execute(hdr.falcon.cluster_id); // Read last idle count for vcluster
                    }

                    if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_REMOVE) {
                        remove_linked_sq.execute(hdr.falcon.cluster_id); // Get ID of the Spine that the leaf reports to   
                    } else {
                        falcon_md.linked_sq_id = read_update_linked_sq.execute(hdr.falcon.cluster_id);
                    }
                    

                    /**Stage 1
                     * get_idle_index, dep: get_worker_start_idx @st0, idle_count @st 0
                     * get_cluster_num_valid_ds
                     * gen_random_workers_16
                     Registers:
                     * aggregate_queue_len, dep: queue_len_unit @st0
                     * iq_len_1
                     * probed_id
                    */
                    // INFO: Compiler bug, if calculate the index for reg action here, compiler complains but if in action its okay!
                    @stage(1){
                        get_idle_index();
                        get_cluster_num_valid_ds.apply();
                        gen_random_workers_16();
                        if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE || hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                            //@st st_aggregate_queue = 0
                            falcon_md.aggregate_queue_len = update_read_aggregate_queue_len.execute(hdr.falcon.cluster_id);

                        } else if(hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_RESPONSE) {
                            falcon_md.last_iq_len = read_update_spine_iq_len_1.execute(hdr.falcon.cluster_id);
                            falcon_md.last_probed_id = read_update_spine_probed_id.execute(hdr.falcon.cluster_id);
                        } 
                    }


                    
                    /** Stage 2
                     * get_curr_idle_index, dep: get_idle_index() @st1
                     * compare_spine_iq_len
                     * adjust_random_range
                     Registers:
                     * All of the worker qlen related regs, deps: resource limit of prev stage  
                    */
                    @stage(2){
                        if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK){
                            get_curr_idle_index(); // decrement the index so we read the correct idle worker id
                            adjust_random_range.apply();
                            
                            
                            // falcon_md.worker_qlen_3 = read_queue_len_list_3.execute(hdr.falcon.cluster_id);
                            // falcon_md.worker_qlen_4 = read_queue_len_list_4.execute(hdr.falcon.cluster_id);

                        } else if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                            if (falcon_md.linked_sq_id != 0xFF) {
                                    /* 
                                    Desired behaviour: Mirror premitive (emit invoked in ingrdeparser) will send the original response
                                    Here we modify the original packet and send it as a ctrl pkt to the linked spine.
                                    TODO: Might not work as we expect.
                                    */
                                    convert_pkt_to_sq_signal();
                                    hdr.falcon.dst_id = falcon_md.linked_sq_id;
                            }
                            // write_queue_len_list_1.execute(hdr.falcon.src_id);
                            // write_queue_len_list_2.execute(hdr.falcon.src_id);
                            // write_queue_len_list_3.execute(hdr.falcon.src_id);
                            // write_queue_len_list_4.execute(hdr.falcon.src_id);
                        } else if (hdr.falcon.pkt_type == PKT_TYPE_SCAN_QUEUE_SIGNAL) {
                            if (falcon_md.linked_sq_id == 0xFFFF) { // Not linked to another spine so we reply back with queue signal
                                convert_pkt_to_sq_signal();
                                hdr.falcon.dst_id = hdr.falcon.src_id;
                            }
                        }   
                        compare_spine_iq_len();
                    } 
                    /** Stage 3
                     * Register:
                     * idle_list, dep: idle_count @st0, get_idle_index() @st 1, get_curr_idle_index() @st 2
                    */ 
                    @stage(3){
                        if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) { 
                            add_to_idle_list.execute(falcon_md.idle_worker_index);

                        } else if(hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                            if (falcon_md.cluster_idle_count != 0) {
                                falcon_md.idle_worker_id = read_idle_list.execute(falcon_md.idle_worker_index);
                            } else {
                                offset_random_ids();
                            }
                        } else if (hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_RESPONSE) {
                            if (falcon_md.last_probed_id != 0xFF) { // This is the second probe response
                                if (falcon_md.selected_spine_iq_len == falcon_md.last_iq_len) { // last spine selected
                                    hdr.falcon.dst_id = falcon_md.last_probed_id;
                                } else {
                                    hdr.falcon.dst_id = hdr.falcon.src_id;
                                }
                                hdr.falcon.pkt_type = PKT_TYPE_IDLE_SIGNAL;
                            }
                        }
                    } 
                    

                    /** Stage 4
                     * 
                    */
                    if (ig_intr_md.resubmit_flag != 0) { // packet is resubmitted
                        inc_queue_len_list_1.execute(falcon_md.task_resub_hdr.udpate_worker_index);
                        inc_queue_len_list_2.execute(falcon_md.task_resub_hdr.udpate_worker_index);
                    }
                    else {
                        if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK){
                            falcon_md.worker_qlen_1 = read_queue_len_list_1.execute(falcon_md.random_downstream_id_1);
                            falcon_md.worker_qlen_2 = read_queue_len_list_2.execute(falcon_md.random_downstream_id_2);
                        } 
                    }
                    // LAST STAGE
                    if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                        if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) {
                            if (falcon_md.cluster_idle_count == 1) { // Leaf just became idle so needs to announce to the spine layer
                                    hdr.falcon.pkt_type = PKT_TYPE_PROBE_IDLE_QUEUE; // Change packet type to probe
                                    gen_random_probe_group();
                            }
                        }
                        if (falcon_md.linked_sq_id != 0xFF) {
                            
                            /* 
                            Desired behaviour: Mirror premitive (emit invoked in ingrdeparser) will send the original response
                            Here we modify the original packet and send it as a ctrl pkt to the linked spine.
                            TODO: Might not work as we expect.
                            */
                            // Set different mirror types for different headers if needed
                            ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_WORKER_RESPONSE; 
                            
                        }
                    }
                    // } 
                    
                    

                    //     // TODO: Do this in server agent to save computation resource at switch (send adjust index as src_id)
                        
                    //     // Known issue: 
                    //     // Also 
                    //     // @stage(1){
                    //     //     get_worker_index();
                    //     // }
                    //     if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) {
                    //          // Read last idle count for vcluster
                    //         // @st >= st_idle_count --> st=1
                    //         get_idle_index (); // Get the index of idle worker in idle list (pointes to next available index)
                    //         // @st st_idle_list >=3 (restricted by other branch)
                    //         add_to_idle_list.execute(falcon_md.idle_worker_index); /// Add src_id to Idle list.
                    //         // @st >= st_idle_count --> st=1
                    //         if (falcon_md.cluster_idle_count == 1) { // Leaf just became idle so needs to announce to the spine layer
                    //             // @st >=1
                    //             hdr.falcon.pkt_type = PKT_TYPE_PROBE_IDLE_QUEUE; // Change packet type to probe
                    //             /* 
                    //              TODO: Check details of ig_intr_tm_md.mcast_grp_a, mcast_grp_b
                    //              TODO: How to route packet to spines in other pods that are multi hops away?
                    //             */
                    //             // @INFO: Compiler put this on stage 2 although it can be placed on 1 (explicitly set)
                    //             @stage(1){
                    //                 falcon_md.rand_probe_group = (bit<16>)random_probe_group.get(); 
                    //             }
                    //             // @st >= rand_probe_group --> st=2 INFO: This maps to stage 3 don't know why?
                    //             @stage(2){
                    //                 gen_random_probe_group();
                    //             }
                    //         }
                    //     }
                        
                    //     write_queue_len_list_1.execute(hdr.falcon.src_id);
                    //     write_queue_len_list_2.execute(hdr.falcon.src_id);
                    //     write_queue_len_list_3.execute(hdr.falcon.src_id);
                    //     write_queue_len_list_4.execute(hdr.falcon.src_id);
                    //     // write_queue_len_list_5.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_6.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_7.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_8.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_9.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_10.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_11.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_12.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_13.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_14.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_15.execute(falcon_md.worker_index);
                    //     // write_queue_len_list_16.execute(falcon_md.worker_index);
                    //     //... Rest of workers

                        
                    //     if (falcon_md.linked_sq_id != 0xFF) {
                    //         // Set different mirror types for different headers if needed
                    //         ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_WORKER_RESPONSE; 
                    //         /* 
                    //         Desired behaviour: Mirror premitive (emit invoked in ingrdeparser) will send the original response
                    //         Here we modify the original packet and send it as a ctrl pkt to the linked spine.
                    //         TODO: Might not work as we expect.
                    //         */
                    //         hdr.falcon.pkt_type = PKT_TYPE_QUEUE_SIGNAL;
                    //         hdr.falcon.qlen = falcon_md.aggregate_queue_len;
                    //         hdr.falcon.dst_id = falcon_md.linked_sq_id;
                    //     }
                    // } 
                    // else if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                    //     // @st st_idle_count >= 0
                        
                    //     // @st st_aggregate_queue_len >= 0
                    //     if (falcon_md.cluster_idle_count > 0) {
                    //         // @st >= st_idle_count --> st=1
                    //         get_idle_index();
                    //         // @st >= get_idle_index --> st=2
                    //         get_curr_idle_index(); // Decrements the idle index so we read the correct index (stack peak)
                    //         // @st st_idle_list >= get_curr_idle_index --> st=3
                    //         hdr.falcon.dst_id = read_idle_list.execute(falcon_md.idle_worker_index);
                    //     } else {
                    //         get_cluster_num_valid_ds.apply(); // Get num workers in this rack for this vcluster? Configured by ctrl plane.
                    //         gen_random_workers_16();    
                    //         adjust_random_range.apply();
                            
                    //         falcon_md.worker_qlen_1 = read_queue_len_list_1.execute(hdr.falcon.cluster_id);
                    //         falcon_md.worker_qlen_2 = read_queue_len_list_2.execute(hdr.falcon.cluster_id);
                    //         falcon_md.worker_qlen_3 = read_queue_len_list_3.execute(hdr.falcon.cluster_id);
                    //         falcon_md.worker_qlen_4 = read_queue_len_list_4.execute(hdr.falcon.cluster_id);

                    //         // falcon_md.worker_qlen_5 = read_queue_len_list_5.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_6 = read_queue_len_list_6.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_7 = read_queue_len_list_7.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_8 = read_queue_len_list_8.execute(hdr.falcon.cluster_id);

                    //         // falcon_md.worker_qlen_9 = read_queue_len_list_9.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_10 = read_queue_len_list_10.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_11 = read_queue_len_list_11.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_12 = read_queue_len_list_12.execute(hdr.falcon.cluster_id);

                    //         // falcon_md.worker_qlen_13 = read_queue_len_list_13.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_14 = read_queue_len_list_14.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_15 = read_queue_len_list_15.execute(hdr.falcon.cluster_id);
                    //         // falcon_md.worker_qlen_16 = read_queue_len_list_16.execute(hdr.falcon.cluster_id);
                    //         //... Rest of workers

                    //         assign_qlen_random1.apply();
                    //         assign_qlen_random2.apply();
                    //         compare_queue_len();
                    //         // COMPILE ERROR: Uncomment lines 623 to 627 to reproduce the error
                    //         // if(falcon_md.selected_worker_qlen == falcon_md.random_worker_qlen_1) {
                    //         //     hdr.falcon.dst_id = falcon_md.random_downstream_id_1;
                    //         // } else {
                    //         //     hdr.falcon.dst_id = falcon_md.random_downstream_id_2;
                    //         // }
                    //     }
                        
                    //     // Rack not idle anymore after this assignment
                    //     // TODO: Currently, leaf will only send PKT_TYPE_IDLE_REMOVE when there was some linked IQ 
                    //     //  This means that for task that is coming because of random decision we are not sending Idle remove
                    //     //  This limitation is because spine can not iterate over the idle list to remove a switch at the middle it has a stack and can pop only!
                    //     if (falcon_md.cluster_idle_count == 0 && falcon_md.linked_iq_id != 0xFFFF) {
                    //         ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_NEW_TASK;
                            
                    //         /* 
                    //         Desired behaviour: Mirror premitive (emit invoked in ingrdeparser) will send the original task packet to the 
                    //         Here we modify the original packet and send it as a ctrl pkt to the linked IQ spine.
                    //         TODO: Might not work as we expect.
                    //         */
                            
                    //         // Reply to the spine with Idle remove
                    //         hdr.falcon.dst_id = read_reset_linked_iq.execute(hdr.falcon.cluster_id);   
                    //         hdr.falcon.pkt_type = PKT_TYPE_IDLE_REMOVE;
                    //         //ig_intr_tm_md.ucast_egress_port = ig_intr_md.ingress_port;
                    //     }
                    
                    // } else if (hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_RESPONSE) {
                        
                    //     if (falcon_md.cluster_idle_count > 0) { // Still idle workers available
                            
                    //         bit<8> last_iq_len;
                    //         bit<16> last_probed_id;
                    //         last_iq_len = read_update_spine_iq_len_1.execute(hdr.falcon.cluster_id);
                    //         last_probed_id = read_update_spine_probed_id.execute(hdr.falcon.cluster_id);
                    //         if (last_probed_id != 0xFF) { // This is the first probe
                    //             if (last_iq_len < 3) { //TODO: Fix comparison here
                    //                 hdr.falcon.dst_id = last_probed_id;
                    //             } else { // Send back
                    //                 hdr.falcon.dst_id = hdr.falcon.src_id;
                    //             }
                    //             hdr.falcon.pkt_type = PKT_TYPE_IDLE_SIGNAL;
                    //         }
                    //     }
                    // } else if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_REMOVE) {
                    //     _drop();
                    // }

                    forward_falcon_switch_dst.apply();
                    
                }  else if (hdr.ipv4.isValid()) { // Regular switching procedure
                    // TODO: Not ported the ip matching tables for now, do we need them?
                    
                    _drop();
                } else {
                    _drop();
                }
            }
        }

control LeafIngressDeparser(
        packet_out pkt,
        inout falcon_header_t hdr,
        in falcon_metadata_t falcon_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {
         
    Mirror() mirror;

    apply {
        if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_WORKER_RESPONSE) {
            
            /* 
             See page 58: P4_16 Tofino Native Architecture
             Application Note – (Public Version Mar 2021)
             In summary: this should replicate the initial received packet *Before any modifications* to the configured ports.
             Here we are using the dst_id as mirror Session ID
             Control plane needs to add mapping between session ID (we use dst_id aas key) and 
             output port (value) (same table as falcon forward in ingress)
            */
            // TODO: Bug Report to community. emit() should support single param interface when no header is needed. But gets compiler internal error! 
            mirror.emit<empty_t>((MirrorId_t) hdr.falcon.dst_id, {}); 
        }  else if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_NEW_TASK) {

        }
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.udp);
        pkt.emit(hdr.falcon);
    }
}

// Empty egress parser/control blocks
parser FalconEgressParser(
        packet_in pkt,
        out falcon_header_t hdr,
        out eg_metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        pkt.extract(eg_intr_md);
        transition accept;
    }
}

control FalconEgressDeparser(
        packet_out pkt,
        inout falcon_header_t hdr,
        in eg_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md) {
    apply {}
}

control FalconEgress(
        inout falcon_header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
        inout egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_intr_oport_md) {
    apply {}
}