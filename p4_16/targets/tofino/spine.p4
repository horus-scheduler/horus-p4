#include <core.p4>
#include <tna.p4>

#include "common/headers.p4"
#include "common/util.p4"
#include "headers.p4"


// TODO: Remove linked spine iq when new task comes and idlecount is 1
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
                value = value + 1; 
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

    Register<bit<16>, _>(MAX_VCLUSTERS) queue_signal_count; // Stores number of qlen signals (from leafs) available for each vcluster
        RegisterAction<bit<16>, _, bit<16>>(queue_signal_count) read_queue_signal_count = { 
            void apply(inout bit<16> value, out bit<16> rv) {
                rv = value; // Retruns val    
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(queue_signal_count) read_and_inc_queue_signal_count = { 
            void apply(inout bit<16> value, out bit<16> rv) {
                rv = value; // Retruns val before modificaiton
                value = value + 1; 
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(queue_signal_count) reset_queue_signal_count = { 
            void apply(inout bit<16> value, out bit<16> rv) {
                value = 0;
            }
        };

    Register<queue_len_t, _>(MAX_TOTAL_LEAFS) queue_len_list_1; // List of queue lens for all vclusters
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_1) inc_queue_len_list_1 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = value + 1;
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
        RegisterAction<queue_len_t, _, queue_len_t>(queue_len_list_2) inc_queue_len_list_2 = {
            void apply(inout queue_len_t value, out queue_len_t rv) {
                value = value + 1;
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

    Register<leaf_id_t, _>(MAX_TOTAL_LEAFS) lid_list_1; // List of leaf IDs that we are tracking their queue signal (so we can select them when comparing the queue_len_list)
        RegisterAction<bit<16>, _, bit<16>>(lid_list_1) add_to_lid_list_1 = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = falcon_md.cluster_absolute_leaf_index;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(lid_list_1) read_lid_list_1 = {
            void apply(inout bit<16> value, out bit<16> rv) {
                rv = value;
            }
        };
     Register<leaf_id_t, _>(MAX_TOTAL_LEAFS) lid_list_2; // List of leaf IDs that we are tracking their queue signal (so we can select them when comparing the queue_len_list)
        RegisterAction<bit<16>, _, bit<16>>(lid_list_2) add_to_lid_list_2 = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = falcon_md.cluster_absolute_leaf_index;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(lid_list_2) read_lid_list_2 = {
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
        falcon_md.idle_ds_index = falcon_md.cluster_ds_start_idx + falcon_md.cluster_idle_count;
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

    /* 
     * One of the two following tables will apply depending on wether 
     * we want to select a random lea from all leafs or want to select samples from available queue signals
    */
    table adjust_random_range_all_leafs { // Adjust the random generated number (16 bit) based on number of leafs for vcluster
        key = {
            falcon_md.cluster_num_valid_ds: exact; 
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
    action act_get_cluster_num_valid_leafs(bit<16> num_leafs, bit<16> max_linked_leafs) {
        falcon_md.cluster_num_valid_ds = num_leafs;
        falcon_md.cluster_max_linked_leafs = max_linked_leafs;
    }
    table get_cluster_num_valid_leafs {
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

    action gen_random_probe_group() { // For probing two out of n spine schedulers
        ig_intr_tm_md.mcast_grp_a = (MulticastGroupId_t) 1; // Assume all use a single grp level 1
        /* 
          Limitation: Casting the output of Random instance and assiging it directly to mcast_grp_b did not work. 
          Had to assign it to a 16 bit meta field and then assign to mcast_group. 
        */
        // Different out ports for level 2 randomly generated
        // Here we use the same random 16 bit number generated for downstream ID to save resources
        ig_intr_tm_md.mcast_grp_b = falcon_md.random_ds_index_1; 
    }

    action set_broadcast_group() { // For anouncing that this leaf knos some idle leafs and no longer needs sq updates
        ig_intr_tm_md.mcast_grp_a = (MulticastGroupId_t) 1; // Assume all use a single grp level 1
        
        ig_intr_tm_md.mcast_grp_b = 0xFF; // TODO: define the "broadcast" mcast_grp
    }

    action convert_pkt_to_scan_queue() {
        hdr.falcon.pkt_type = PKT_TYPE_SCAN_QUEUE_SIGNAL; 
    }

    action convert_pkt_to_probe_idle_resp() {
        hdr.falcon.pkt_type = PKT_TYPE_PROBE_IDLE_RESPONSE;  // Change packet type
        hdr.falcon.qlen = (bit<8>) falcon_md.cluster_idle_count; // Get num_idles for reporting to leaf
        hdr.falcon.dst_id = hdr.falcon.src_id; // Send back to leaf that sent the probe
    }
    
    action compare_queue_len() {
        falcon_md.selected_ds_qlen = min(falcon_md.random_ds_qlen_1, falcon_md.random_ds_qlen_2);
    }
    action calculate_num_signals(){
        falcon_md.num_additional_signal_needed = falcon_md.cluster_max_linked_leafs - falcon_md.cluster_num_valid_queue_signals;
    }

    // This gives us the 1/#workers for each leaf switch in each vcluster 
    action act_set_queue_len_unit(len_fixed_point_t cluster_unit) {
        falcon_md.queue_len_unit = cluster_unit;
    }
    table set_queue_len_unit {
        key = {
            hdr.falcon.local_cluster_id: exact;
            hdr.falcon.dst_id: exact;
        }
        actions = {
            act_set_queue_len_unit;
            NoAction;
        }
        size = HDR_CLUSTER_ID_SIZE;
        default_action = NoAction;
    }

    // action offset_random_ids() {
    //     falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 + falcon_md.cluster_ds_start_idx;
    //     falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 + falcon_md.cluster_ds_start_idx;
    // }

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
        if (hdr.falcon.dst_id == SWITCH_ID) { // If this packet is destined for this spine do falcon processing ot. its just an intransit packet we need to forward on correct port
            @stage(0) {
                get_leaf_start_idx ();
                get_cluster_num_valid_leafs.apply();
                gen_random_leaf_index_16();
            
                if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK || hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_QUEUE) {
                    falcon_md.cluster_idle_count = read_idle_count.execute(hdr.falcon.cluster_id); // Get num_idle leafs (pointer to top of stack)
                    falcon_md.cluster_num_valid_queue_signals = read_queue_signal_count.execute(hdr.falcon.cluster_id); // How many queue signals available
                } else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_SIGNAL) {
                    falcon_md.cluster_idle_count = read_and_inc_idle_count.execute(hdr.falcon.cluster_id);
                    reset_queue_signal_count.execute(hdr.falcon.cluster_id);
                }  else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) {
                    falcon_md.cluster_idle_count = read_and_dec_idle_count.execute(hdr.falcon.cluster_id);
                    
                } else if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_SIGNAL_INIT) {
                    falcon_md.cluster_num_valid_queue_signals = read_and_inc_queue_signal_count.execute(hdr.falcon.cluster_id);
                }
            }

            @stage(1) {
                get_array_indices();
                if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) {
                    if (falcon_md.cluster_idle_count == 0) { // No more idle info so we ask for the queue length signals
                        set_broadcast_group();
                    }
                }
            }

            @stage(2) {
                if (falcon_md.cluster_num_valid_queue_signals > 1) {
                    adjust_random_range_sq_leafs.apply(); //  We want to select a random worker from available qlen signals
                } else {
                    adjust_random_range_all_leafs.apply(); // We want to select a random worker from all workers
                }
                if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK){
                    decrement_indices(); // decrement the index so we read the correct idle leaf ID
                }
            }

            @stage(3) {
                if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                    falcon_md.random_downstream_id_1 = read_lid_list_1.execute(falcon_md.random_ds_index_1); // Read the leaf ID 1 from list1
                    falcon_md.random_downstream_id_2 = read_lid_list_2.execute(falcon_md.random_ds_index_2); // Read the leaf ID 2 from list2
                    falcon_md.idle_ds_id = read_idle_list.execute(falcon_md.idle_ds_index);
                }
                else if(hdr.falcon.pkt_type == PKT_TYPE_IDLE_SIGNAL) {
                    add_to_idle_list.execute(falcon_md.idle_ds_index);
                } else if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_SIGNAL_INIT) {
                    add_to_lid_list_1.execute(falcon_md.lid_ds_index); // Write src_id to next available leaf id array index
                    add_to_lid_list_2.execute(falcon_md.lid_ds_index);   
                }
            }

            @stage(4) {
                if(hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                    if (ig_intr_md.resubmit_flag == 0) { // First pass
                        falcon_md.random_ds_qlen_1 = read_queue_len_list_1.execute(falcon_md.random_downstream_id_1); // Read qlen for leafID1
                        falcon_md.random_ds_qlen_2 = read_queue_len_list_2.execute(falcon_md.random_downstream_id_2); // Read qlen for leafID2
                    } else { // Second pass, resubmitted packet
                        inc_queue_len_list_1.execute(falcon_md.task_resub_hdr.udpate_ds_index);
                        inc_queue_len_list_2.execute(falcon_md.task_resub_hdr.udpate_ds_index);
                        hdr.falcon.dst_id = falcon_md.task_resub_hdr.udpate_ds_index;
                    }
                } else if (hdr.falcon.pkt_type == PKT_TYPE_QUEUE_SIGNAL_INIT || hdr.falcon.pkt_type == PKT_TYPE_QUEUE_SIGNAL){
                    write_queue_len_list_1.execute(falcon_md.cluster_absolute_leaf_index); // Write the qlen at corresponding index for the leaf in this cluster
                    write_queue_len_list_2.execute(falcon_md.cluster_absolute_leaf_index); // Write the qlen at corresponding index for the leaf in this cluster
                }
            }

            @stage(5) {
                compare_queue_len();
                calculate_num_signals();
            }

            @stage(6) {
                if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK){
                    if (falcon_md.selected_ds_qlen == falcon_md.random_ds_qlen_1) {
                        falcon_md.task_resub_hdr.udpate_ds_index = falcon_md.random_downstream_id_1;
                    } else {
                        falcon_md.task_resub_hdr.udpate_ds_index = falcon_md.random_downstream_id_2;
                        //falcon_md.mirror_dst_id = falcon_md.random_downstream_id_2;
                    }
                    ig_intr_dprsr_md.resubmit_type = RESUBMIT_TYPE_NEW_TASK;
                }
            }

            @stage(7) {
                if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                    if (falcon_md.num_additional_signal_needed > 0) { // Spine still needs to collect more queue length signals
                        hdr.falcon.dst_id = falcon_md.mirror_dst_id; // No need for mirroring, just set dst_id
                    }
                } else if (hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_QUEUE) {
                    // had to put changes in an action "convert_pkt_to_probe_idle_resp()" without this the p4i shows only the first hdr modification!
                    // Not sure why but other lines get eliminated and not placed by the compiler! TODO: Check in tests, bug report to community.
                    convert_pkt_to_probe_idle_resp();
                } else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) {
                    if (falcon_md.cluster_idle_count == 0) { // No more idle info so we ask for the queue length signals
                        convert_pkt_to_scan_queue();
                    }
                }
                hdr.falcon.src_id = SWITCH_ID;
            }

        // if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
            
        //     if (falcon_md.cluster_idle_count > 0) { // Spine knows about some idle leafs 
                
        //     } else {
                
        //         if (falcon_md.cluster_num_valid_ds < MAX_LINKED_LEAFS) { // Spine still needs to collect more queue length signals
        //             convert_pkt_to_scan_queue();
        //             set_broadcast_group(); // TODO: Ctrl plane design: random probing using mcast groups, 
        //             ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_NEW_TASK; // Mirroring the task pkt to selected leaf for scheduling, modify original packet for sending scan probe
        //         } else {
                    
        //         }
        //     }
        // }
        // else if (hdr.falcon.pkt_type == PKT_TYPE_IDLE_REMOVE) {
        //     // TODO: For now, leaf will only send back IDLE_REMOVE to the spine as reply. 
        //     // Sometimes, We need to remove the switch with <src_id> from the idle list of the linked_iq as a result of random tasks.
        //     //  but don't have access to its index at spine.
        //     // Here we pop the most recent from stack. This also has a concurrency bug!
        //     // As a workaround: Spine stores the array index of the idle leafs. When receives idle_remove, marks that index (e.g 0b1). 
        //     // When assining tasks using idle leaf signal, it checks the leaf's index in that array, If the mark shows removed, it should havae been removed and it was a mistake so recirculate the packet and decrement the count 
        //     @stage(0){
        //     read_and_dec_idle_count.execute(hdr.falcon.cluster_id);
        //     }
        // }            

        // /** Stage 5
        //  * 
        // */
        
        }
        
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
