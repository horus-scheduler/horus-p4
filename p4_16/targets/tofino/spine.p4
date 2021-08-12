#include <core.p4>
#include <tna.p4>

#include "common/headers.p4"
#include "common/util.p4"
#include "headers.p4"


// TODO: Remove linked spine iq when new task comes and idlecount is 1
/*
 * Notes:
 *  There are some minor differences from the original design (used in simulations)
 *  * We can not send the "queue remove" packet to unlink all of the queue length linkage of leafs when spine is aware of idle leafs.
 *    This was designed to avoid msg overhead in case an spine is aware of idle workers and does not need to get updates for queue lengths.
 *    Its not trivial how to do this in P4, we can not make multicast config in dataplane. 
 *    As a workaround: we remove the link for each leaf when we get a queue signal form it (in case spine knows idle leafs).
 *    We can also send a broadcast to unlink them. TODO: Which approach? Modify simulations to reflect the overheads associated with this design choice.

*/

// Hardcoded ID of each switch, needed to let switches to communicate with each other
#define SWITCH_ID 16w100 

control SpineIngress(
        inout falcon_header_t hdr,
        inout falcon_metadata_t falcon_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md) {

    Random<bit<16>>() random_ds_id;

    /********  Register decelarations *********/
    Register<leaf_id_t, _>(MAX_LEAFS) idle_list; // Maintains the list of idle leafs for each vcluster (array divided based on cluster_id)
        RegisterAction<bit<16>, _, bit<16>>(idle_list) add_to_idle_list = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = hdr.falcon.src_id;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(idle_list) write_idle_list = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = falcon_md.task_resub_hdr.ds_index_2;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(idle_list) read_idle_list = {
            void apply(inout bit<16> value, out bit<16> rv) {
                rv = value;
            }
        };

    Register<bit<8>, _>(MAX_VCLUSTERS) idle_count; // Stores idle count for each vcluster
        RegisterAction<bit<8>, _, bit<8>>(idle_count) read_idle_count = { 
            void apply(inout bit<8> value, out bit<8> rv) {
                rv = value; // Retruns val    
            }
        };
        RegisterAction<bit<8>, _, bit<8>>(idle_count) read_and_inc_idle_count = { 
            void apply(inout bit<8> value, out bit<8> rv) {
                rv = value; // Retruns val before modificaiton
                value = value + 1; 
            }
        };
        RegisterAction<bit<8>, _, bit<8>>(idle_count) read_and_dec_idle_count = { 
            void apply(inout bit<8> value, out bit<8> rv) {
                if (value > 0) { 
                    rv = value;
                    value = value - 1;
                }
            }
        };

    Register<queue_len_t, _>(MAX_TOTAL_LEAFS) queue_len_list_1; // List of queue lens for all vclusters
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_1) update_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = falcon_md.selected_ds_qlen;
                rv = value;
            }
        };
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_1) read_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                rv = value;
            }
        };
         RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_1) write_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = hdr.falcon.qlen;
                rv = value;
            }
        };


    Register<queue_len_t, _>(MAX_TOTAL_LEAFS) queue_len_list_2; // List of queue lens for all vclusters
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_2) update_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = falcon_md.selected_ds_qlen;
                rv = value;
            }
        };
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_2) read_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                rv = value;
            }
        };
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_2) write_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = hdr.falcon.qlen;
                rv = value;
            }
        };

    Register<queue_len_t, _>(MAX_TOTAL_LEAFS) deferred_queue_len_list_1; // List of queue lens for all vclusters
        RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_1) check_deferred_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                if (value <= falcon_md.queue_len_diff) { // Queue len drift is not large enough to invalidate the decision
                    value = value + falcon_md.queue_len_unit;
                    rv = 0;
                } else {
                    rv = value; // to avoid using another stage for this calculation
                }
            }
        };
         RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_1) reset_deferred_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = 0;
                rv = value;
            }
        };
        RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_1) inc_deferred_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                    value = value + falcon_md.queue_len_unit;
            }
        };

    Register<queue_len_t, _>(MAX_TOTAL_LEAFS) deferred_queue_len_list_2; // List of queue lens for all vclusters
        RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_2) inc_deferred_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = value + falcon_md.queue_len_unit;
                rv = value;
            }
        };
        RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_2) read_deferred_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                rv = value + falcon_md.not_selected_ds_qlen;
            }
        };
        RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_2) reset_deferred_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = 0;
                rv = value;
            }
        };

    Register<bit<16>, _>(MAX_TOTAL_LEAFS) idle_list_idx_mapping; // Maintains the position of leaf in the idle list so we can later remove it in O(1)
        RegisterAction<bit<16>, _, bit<16>>(idle_list_idx_mapping) write_idle_list_idx_mapping = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = falcon_md.idle_ds_index;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(idle_list_idx_mapping) update_idle_list_idx_mapping = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = falcon_md.task_resub_hdr.ds_index_1;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(idle_list_idx_mapping) read_idle_list_idx_mapping = { // Read last value update current to falcon_md.cluster_idle_count -1 (we swap with top element when removing)
            void apply(inout bit<16> value, out bit<16> rv) {
                rv = value;
            }
        };
    /********  Action/table decelarations *********/
    action _drop() {
        ig_intr_dprsr_md.drop_ctl = 0x1; // Drop packet.
    }

    action get_leaf_start_idx () {
        falcon_md.cluster_ds_start_idx = (bit <16>) (hdr.falcon.cluster_id * MAX_LEAFS_PER_CLUSTER);
    }
    action get_array_indices () {
        falcon_md.idle_ds_index = falcon_md.cluster_ds_start_idx + (bit<16>)falcon_md.cluster_idle_count;
        falcon_md.lid_ds_index = falcon_md.cluster_ds_start_idx + falcon_md.cluster_num_valid_queue_signals;
        falcon_md.cluster_absolute_leaf_index = falcon_md.cluster_ds_start_idx + hdr.falcon.src_id;
    }

    action decrement_indices() {
        falcon_md.idle_ds_index = falcon_md.idle_ds_index -1;
        falcon_md.lid_ds_index = falcon_md.lid_ds_index -1;
    }

    action gen_random_leaf_index_16() {
        falcon_md.random_ds_index_1 = (bit<16>) random_ds_id.get();
        falcon_md.random_ds_index_2 = (bit<16>) random_ds_id.get();

    }
    action adjust_random_leaf_index_8() {
        falcon_md.random_ds_index_1 = falcon_md.random_ds_index_1 >> 8;
        falcon_md.random_ds_index_2 = falcon_md.random_ds_index_2 >> 8;
    }

    action adjust_random_leaf_index_4() {
        falcon_md.random_ds_index_1 = falcon_md.random_ds_index_1 >> 12;
        falcon_md.random_ds_index_2 = falcon_md.random_ds_index_2 >> 12;
    }

    action adjust_random_leaf_index_2() {
        falcon_md.random_ds_index_1 = falcon_md.random_ds_index_1 >> 14;
        falcon_md.random_ds_index_2 = falcon_md.random_ds_index_2 >> 14;
    }

    action adjust_random_leaf_index_1() {
        falcon_md.random_ds_index_1 = falcon_md.random_ds_index_1 >> 15;
        falcon_md.random_ds_index_2 = falcon_md.random_ds_index_2 >> 15;
    }

    table adjust_random_range_sq_leafs { // Adjust the random generated number (16 bit) based on number of available queue len signals
        key = {
            falcon_md.cluster_num_valid_queue_signals: exact; 
        }
        actions = {
            adjust_random_leaf_index_8(); // == 8
            adjust_random_leaf_index_4(); // == 4
            adjust_random_leaf_index_2(); // == 2
            adjust_random_leaf_index_1(); // == 1
            NoAction; // == 16
        }
        size = 16;
        default_action = NoAction;
    }
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

    /* 
     * The tables gives dataplane the number of leafs for a vcluster (depending on worker resource allocations)
     * Also, table gives the dp the max number of sq signals that it can aquire:
     *  This is to ensure that we balance the signals about racks (qlens) between the spine schedulers 
     *  for each vCluster (vc), max_linked_leafs  is calculated as: # leafs (belonging to vc) / # spine schedulers
     */
    action act_get_cluster_num_valid_leafs(bit<16> num_leafs) {
        falcon_md.cluster_num_valid_ds = num_leafs;
    }
    table get_cluster_num_valid_leafs { // TODO: fix typo: Leaves !
        key = {
            hdr.falcon.cluster_id : exact;
        }
        actions = {
            act_get_cluster_num_valid_leafs;
            NoAction;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = NoAction;
    }

    action compare_queue_len() {
        falcon_md.selected_ds_qlen = min(falcon_md.random_ds_qlen_1, falcon_md.random_ds_qlen_2);
    }
    action compare_correct_queue_len() {
        falcon_md.min_correct_qlen = min(falcon_md.task_resub_hdr.qlen_1, falcon_md.task_resub_hdr.qlen_2);
    }

    action calculate_queue_len_diff() {
        falcon_md.queue_len_diff = falcon_md.not_selected_ds_qlen - falcon_md.selected_ds_qlen;
    }
    action get_larger_queue_len() {
        falcon_md.not_selected_ds_qlen = max(falcon_md.random_ds_qlen_1, falcon_md.random_ds_qlen_2);
    }

    // This gives us the 1/#workers for each leaf switch in each vcluster 
    action act_set_queue_len_unit_1(len_fixed_point_t cluster_unit) {
        falcon_md.task_resub_hdr.qlen_unit_1 = cluster_unit;
    }
    table set_queue_len_unit_1 {
        key = {
            hdr.falcon.cluster_id: exact;
            falcon_md.random_id_1: exact;
        }
        actions = {
            act_set_queue_len_unit_1;
            NoAction;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = NoAction;
    }

    action act_set_queue_len_unit_2(len_fixed_point_t cluster_unit) {
        falcon_md.task_resub_hdr.qlen_unit_2 = cluster_unit;
    }
    table set_queue_len_unit_2 {
        key = {
            hdr.falcon.cluster_id: exact;
            falcon_md.random_id_2: exact;
        }
        actions = {
            act_set_queue_len_unit_2;
            NoAction;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = NoAction;
    }

    action act_get_rand_leaf_id_2 (bit <16> leaf_id){
        falcon_md.random_id_2 = leaf_id;
    }
    table get_rand_leaf_id_2 {
        key = {
            falcon_md.random_ds_index_2: exact;
            hdr.falcon.cluster_id: exact;
        }
        actions = {
            act_get_rand_leaf_id_2();
            NoAction;
        }
        size = 16;
        default_action = NoAction;
    }
    action act_get_rand_leaf_id_1(bit <16> leaf_id){
        falcon_md.random_id_1 = leaf_id;
    }
    table get_rand_leaf_id_1 {
        key = {
            falcon_md.random_ds_index_1: exact;
            hdr.falcon.cluster_id: exact;
        }
        actions = {
            act_get_rand_leaf_id_1();
            NoAction;
        }
        size = 16;
        default_action = NoAction;
    }

    /********  Control block logic *********/
    apply {
        if (hdr.falcon.isValid()) {  // Falcon packet
            /** Stage 0
             * Registers:
             * idle_count
             * read_queue_signal_count
             * Tables:
             * get_cluster_num_valid_ds
             * get_leaf_start_idx
             * gen_random_leaf_index_16
            */
        // ig_intr_tm_md.ucast_egress_port = 28;
        if (hdr.falcon.dst_id == SWITCH_ID) { // If this packet is destined for this spine do falcon processing ot. its just an intransit packet we need to forward on correct port
            
            @stage(0) {
                get_leaf_start_idx ();
                get_cluster_num_valid_leafs.apply();
                gen_random_leaf_index_16();
                if (ig_intr_md.resubmit_flag != 0) {
                    compare_correct_queue_len();
                } else {
                    if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_SIGNAL) {
                        falcon_md.cluster_idle_count = read_and_inc_idle_count.execute(hdr.falcon.cluster_id);
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) { // Only decrement idle count in first pass of removal
                        falcon_md.cluster_idle_count = read_and_dec_idle_count.execute(hdr.falcon.cluster_id);
                    } else {
                        falcon_md.cluster_idle_count = read_idle_count.execute(hdr.falcon.cluster_id); // Get num_idle leafs (pointer to top of stack)
                    }
                }
            }

            @stage(1) {
                if (ig_intr_md.resubmit_flag!=0) {
                    if (falcon_md.min_correct_qlen == falcon_md.task_resub_hdr.qlen_1) {
                        hdr.falcon.dst_id = falcon_md.task_resub_hdr.ds_index_1;
                        falcon_md.selected_ds_qlen = falcon_md.task_resub_hdr.qlen_1 + falcon_md.task_resub_hdr.qlen_unit_1;
                    } else {
                        hdr.falcon.dst_id = falcon_md.task_resub_hdr.ds_index_2;
                        falcon_md.selected_ds_qlen = falcon_md.task_resub_hdr.qlen_2 + falcon_md.task_resub_hdr.qlen_unit_2;
                    }
                } else {
                    if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) {
                        ig_intr_dprsr_md.resubmit_type = RESUBMIT_TYPE_NEW_TASK; // Trigger resubmit for idle removal
                    }
                    get_array_indices();
                }
            }

            @stage(2) {
                if (ig_intr_md.resubmit_flag != 0){
                    if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) { // Second pass in remove process, update the position for the leaf that was top of idle list in previous pass (we moved it to the position for the leaf that is removed)
                        update_idle_list_idx_mapping.execute(falcon_md.task_resub_hdr.ds_index_2);
                    }
                } else {
                    adjust_random_range_sq_leafs.apply(); //  We want to select a random worker from available qlen signals 

                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        decrement_indices(); // decrement the idle index so we read the correct idle leaf ID
                    }  else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_SIGNAL) {
                        write_idle_list_idx_mapping.execute(falcon_md.cluster_absolute_leaf_index);
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) { // First pass in remove process, find position of the to-be-removed leaf in idle list from mapping reg 
                        falcon_md.task_resub_hdr.ds_index_1 = read_idle_list_idx_mapping.execute(falcon_md.cluster_absolute_leaf_index);
                        decrement_indices(); // decrement the idle index so we read the correct idle leaf ID
                    } 
                }
            }

            @stage(3) {
                if (ig_intr_md.resubmit_flag != 0) {
                    if(hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) { // Second pass for removing idle
                        write_idle_list.execute(falcon_md.task_resub_hdr.ds_index_1);
                    }
                } else {
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK || hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) {
                        falcon_md.idle_ds_id = read_idle_list.execute(falcon_md.idle_ds_index);
                    } else if(hdr.falcon.pkt_type == PKT_TYPE_IDLE_SIGNAL) {
                        add_to_idle_list.execute(falcon_md.idle_ds_index);
                    } 
                }
            }
            // Note: Here lid_list registers does not depend on stage 3 (it depends on stage2) but the resource for registers on stage 3 were limited (6 total regactions)!
            @stage(4) {
                if (ig_intr_md.resubmit_flag == 0) {
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK && falcon_md.cluster_idle_count == 0) {
                        get_rand_leaf_id_1.apply(); // Read the leaf ID 1 associated with generated random index
                        get_rand_leaf_id_2.apply(); // Read the leaf ID 2 associated with generated random index
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) { // This reads the top of 
                        falcon_md.task_resub_hdr.ds_index_2 = falcon_md.idle_ds_id;
                    }
                }
            }

            @stage(5) {
                if (ig_intr_md.resubmit_flag != 0) {
                     if(hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        update_queue_len_list_1.execute(hdr.falcon.dst_id);
                        update_queue_len_list_2.execute(hdr.falcon.dst_id);
                     }
                } else {
                    if(hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK && falcon_md.cluster_idle_count == 0) {
                        falcon_md.random_ds_qlen_1 = read_queue_len_list_1.execute(falcon_md.random_id_1); // Read qlen for leafID1
                        falcon_md.random_ds_qlen_2 = read_queue_len_list_2.execute(falcon_md.random_id_2); // Read qlen for leafID2
                        set_queue_len_unit_1.apply();
                        set_queue_len_unit_2.apply();
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_SIGNAL) {
                        write_queue_len_list_1.execute(falcon_md.cluster_absolute_leaf_index); // Write the qlen at corresponding index for the leaf in this cluster
                        write_queue_len_list_2.execute(falcon_md.cluster_absolute_leaf_index); // Write the qlen at corresponding index for the leaf in this cluster
                    } 
                }
            }

            @stage(6) {
                compare_queue_len();
                get_larger_queue_len();
            }

            @stage(7) {
                if (ig_intr_md.resubmit_flag == 0) {
                    calculate_queue_len_diff();
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        if (falcon_md.cluster_idle_count == 0 && falcon_md.cluster_num_valid_queue_signals > 0) {
                            if (falcon_md.selected_ds_qlen == falcon_md.random_ds_qlen_1) {
                                hdr.falcon.dst_id = falcon_md.random_id_1;
                                falcon_md.task_resub_hdr.ds_index_2 = falcon_md.random_id_2;
                                falcon_md.queue_len_unit = falcon_md.task_resub_hdr.qlen_unit_1;
                            } else {
                                hdr.falcon.dst_id = falcon_md.random_id_2;
                                falcon_md.task_resub_hdr.ds_index_2 = falcon_md.random_id_1;
                                falcon_md.queue_len_unit = falcon_md.task_resub_hdr.qlen_unit_2;
                            }
                        } else {
                            hdr.falcon.dst_id = falcon_md.idle_ds_id;
                        }   
                    }
                }
            }

            @stage(8) {
                if (ig_intr_md.resubmit_flag != 0) {
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        reset_deferred_queue_len_list_1.execute(hdr.falcon.dst_id); // Just updated the queue_len_list so write 0 on deferred reg
                    }
                } else {
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK && falcon_md.cluster_num_valid_queue_signals > 0) {
                        if (falcon_md.random_id_2 != falcon_md.random_id_1) {
                            falcon_md.deferred_qlen_1 = check_deferred_queue_len_list_1.execute(hdr.falcon.dst_id); // Returns QL[dst_id] + Deferred[dst_id]
                            falcon_md.task_resub_hdr.ds_index_1 = hdr.falcon.dst_id;
                        } else { // In case two samples point to the same cell, we do not need to resubmit just increment deferred list
                            inc_deferred_queue_len_list_1.execute(hdr.falcon.dst_id);
                        }
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_SIGNAL) {
                        reset_deferred_queue_len_list_1.execute(hdr.falcon.src_id); // Just updated the queue_len_list so write 0 on deferred reg
                    }   
                }
            }

            @stage(9) {
                if (ig_intr_md.resubmit_flag != 0) {
                    if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        reset_deferred_queue_len_list_2.execute(hdr.falcon.dst_id); // Just updated the queue_len_list so write 0 on deferred reg
                    }
                } else {
                    if (hdr.falcon.pkt_type==PKT_TYPE_QUEUE_SIGNAL || hdr.falcon.pkt_type==PKT_TYPE_QUEUE_SIGNAL_INIT){
                        reset_deferred_queue_len_list_2.execute(hdr.falcon.src_id); // Just updated the queue_len_list so write 0 on deferred reg
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        falcon_md.task_resub_hdr.qlen_1 = falcon_md.deferred_qlen_1 + falcon_md.selected_ds_qlen;
                        if(falcon_md.deferred_qlen_1 == 0) { // This return value means that we do not need to check deffered qlens, difference between samples were large enough that our decision is still valid
                            inc_deferred_queue_len_list_2.execute(hdr.falcon.dst_id); // increment the second copy to be consistent with first one
                        } else { // This means our decision might be invalid, need to check the deffered queue lens and resubmit
                            ig_intr_dprsr_md.resubmit_type = RESUBMIT_TYPE_NEW_TASK;
                            falcon_md.task_resub_hdr.qlen_2 = read_deferred_queue_len_list_2.execute(falcon_md.task_resub_hdr.ds_index_2);
                        }
                    }
                }
            }
        }
        hdr.falcon.src_id = SWITCH_ID;
        forward_falcon_switch_dst.apply();
            
        } else if (hdr.ipv4.isValid()) { // Regular switching procedure
            // TODO: Not ported the ip matching tables for now, do we need them?
            _drop();
        } else {
            _drop();
        }
    }
}

control SpineIngressDeparser(
        packet_out pkt,
        inout falcon_header_t hdr,
        in falcon_metadata_t falcon_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {
         
    Mirror() mirror;
    Resubmit() resubmit;

    apply {
        if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_NEW_TASK) {
            mirror.emit<empty_t>((MirrorId_t) falcon_md.mirror_dst_id, {}); 
        }  
        if (ig_intr_dprsr_md.resubmit_type == RESUBMIT_TYPE_NEW_TASK) {
            resubmit.emit(falcon_md.task_resub_hdr);
        } 
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.udp);
        pkt.emit(hdr.falcon);
    }
}

// Empty egress parser/control blocks
parser SpineEgressParser(
        packet_in pkt,
        out falcon_header_t hdr,
        out eg_metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        pkt.extract(eg_intr_md);
        transition accept;
    }
}

control SpineEgressDeparser(
        packet_out pkt,
        inout falcon_header_t hdr,
        in eg_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md) {
    apply {}
}

control SpineEgress(
        inout falcon_header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
        inout egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_intr_oport_md) {
    apply {}
}
