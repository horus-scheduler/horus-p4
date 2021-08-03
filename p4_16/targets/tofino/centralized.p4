#include <core.p4>
#include <tna.p4>

#include "common/headers.p4"
#include "common/util.p4"
#include "headers.p4"


// TODO: Remove linked spine iq when new task comes and idlecount is 1
/*
 * Note: Difference with simulations
 * In python when taking samples from qlen lists, we just used random.sample() and took K *distinct* samples 
 * In hardware it is not possible to ensure that these values are distinct and two samples might point to same position
 * TODO: Modify the python simulations to reflect this (This is also same for racksched system might affect their performance)
 *
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

control CentralizedIngress(
        inout falcon_header_t hdr,
        inout falcon_metadata_t falcon_md,
        in ingress_intrinsic_metadata_t ig_intr_md,
        in ingress_intrinsic_metadata_from_parser_t ig_intr_prsr_md,
        inout ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md,
        inout ingress_intrinsic_metadata_for_tm_t ig_intr_tm_md) {

            
            Register<queue_len_t, _>(ARRAY_SIZE) queue_len_list_1; // List of queue lens for all vclusters
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

            Register<queue_len_t, _>(ARRAY_SIZE) queue_len_list_2; // List of queue lens for all vclusters
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

            // Register<queue_len_t, _>(ARRAY_SIZE) deferred_queue_len_list_1; // List of queue lens for all vclusters
            //     RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_1) check_deferred_queue_len_list_1 = {
            //         void apply(inout queue_len_t value, out queue_len_t rv) {
            //             if (value <= falcon_md.queue_len_diff) { // Queue len drift is not large enough to invalidate the decision
            //                 value = value + 1;
            //                 rv = 0;
            //             } else {
            //                 rv = value + falcon_md.selected_ds_qlen; // to avoid using another stage for this calculation
            //             }
            //         }
            //     };
            //      RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_1) reset_deferred_queue_len_list_1 = {
            //         void apply(inout queue_len_t value, out queue_len_t rv) {
            //             value = 0;
            //             rv = value;
            //         }
            //     };
            //     RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_1) inc_deferred_queue_len_list_1 = {
            //         void apply(inout queue_len_t value, out queue_len_t rv) {
            //                 value = value + 1;
            //         }
            //     };

            // Register<queue_len_t, _>(ARRAY_SIZE) deferred_queue_len_list_2; // List of queue lens for all vclusters
            //     RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_2) inc_deferred_queue_len_list_2 = {
            //         void apply(inout queue_len_t value, out queue_len_t rv) {
            //             value = value + 1;
            //             rv = value;
            //         }
            //     };
            //     RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_2) read_deferred_queue_len_list_2 = {
            //         void apply(inout queue_len_t value, out queue_len_t rv) {
            //             rv = value + falcon_md.not_selected_ds_qlen;
            //         }
            //     };
            //      RegisterAction<queue_len_t, _, queue_len_t>(deferred_queue_len_list_2) reset_deferred_queue_len_list_2 = {
            //         void apply(inout queue_len_t value, out queue_len_t rv) {
            //             value = 0;
            //             rv = value;
            //         }
            //     };

            /* 
              As a workaround since we can't select the random range in runtime. 
              We get() a random variables and shift it depending on number of workers in rack.
              TODO: This enforces the num workers in rack to be pow of 2. Also, is this biased random?
            */
            Random<bit<16>>() random_worker_id_16;

            action get_worker_start_idx () {
                falcon_md.cluster_ds_start_idx = (bit <16>) (hdr.falcon.cluster_id * MAX_WORKERS_PER_CLUSTER);
            }

            // action get_worker_index () {
            //     falcon_md.worker_index = (bit<16>) hdr.falcon.src_id + falcon_md.cluster_worker_start_idx;
            // }

            action _drop() {
                ig_intr_dprsr_md.drop_ctl = 0x1; // Drop packet.
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

            action act_get_cluster_num_valid(bit<16> num_ds_elements) {
                falcon_md.cluster_num_valid_ds = num_ds_elements;
            }
            table get_cluster_num_valid {
                key = {
                    hdr.falcon.cluster_id : exact;
                }
                actions = {
                    act_get_cluster_num_valid;
                    NoAction;
                }
                size = HDR_CLUSTER_ID_SIZE;
                default_action = NoAction;
            }
 
            action gen_random_workers_16() {
                falcon_md.random_id_1 = (bit<16>) random_worker_id_16.get();
                falcon_md.random_id_2 = (bit<16>) random_worker_id_16.get();
            }
            
            action adjust_random_worker_range_8() {
                falcon_md.random_id_1 = falcon_md.random_id_1 >> 8;
                falcon_md.random_id_2 = falcon_md.random_id_2 >> 8;
            }

            action adjust_random_worker_range_4() {
                falcon_md.random_id_1 = falcon_md.random_id_1 >> 12;
                falcon_md.random_id_2 = falcon_md.random_id_2 >> 12;
            }

            action adjust_random_worker_range_2() {
                falcon_md.random_id_1 = falcon_md.random_id_1 >> 14;
                falcon_md.random_id_2 = falcon_md.random_id_2 >> 14;
            }

            action adjust_random_worker_range_1() {
                falcon_md.random_id_1 = falcon_md.random_id_1 >> 15;
                falcon_md.random_id_2 = falcon_md.random_id_2 >> 15;
            }

            table adjust_random_range_ds { // Reduce the random generated number (16 bit) based on number of workers in rack
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
            
            table adjust_random_range_us { // Reduce the random generated number (16 bit) based on number of workers in rack
                key = {
                    falcon_md.cluster_num_valid_us: exact; 
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
                falcon_md.random_id_1 = falcon_md.random_id_1 + falcon_md.cluster_ds_start_idx;
                falcon_md.random_id_2 = falcon_md.random_id_2 + falcon_md.cluster_ds_start_idx;
            }

            action compare_queue_len() {
                falcon_md.selected_ds_qlen = min(falcon_md.random_ds_qlen_1, falcon_md.random_ds_qlen_2);
            }
            action compare_correct_queue_len() {
                falcon_md.min_correct_qlen = min(falcon_md.task_resub_hdr.qlen_1, falcon_md.task_resub_hdr.qlen_2);
            }
            action get_larger_queue_len() {
                falcon_md.not_selected_ds_qlen = max(falcon_md.random_ds_qlen_1, falcon_md.random_ds_qlen_2);
            }
            
            action calculate_queue_len_diff(){
                falcon_md.queue_len_diff = falcon_md.not_selected_ds_qlen - falcon_md.selected_ds_qlen;
            }

            apply {
                if (hdr.falcon.isValid()) {  // Falcon packet
                    if (ig_intr_md.resubmit_flag != 0) { // Special case: packet is resubmitted just update the indexes
                        @stage(0){
                            compare_correct_queue_len();
                        }
                        @stage(1){
                            if (falcon_md.min_correct_qlen == falcon_md.task_resub_hdr.qlen_1) {
                                hdr.falcon.dst_id = falcon_md.task_resub_hdr.ds_index_1;
                                falcon_md.selected_ds_qlen = falcon_md.task_resub_hdr.qlen_1 + 1;
                            } else {
                                hdr.falcon.dst_id = falcon_md.task_resub_hdr.ds_index_2;
                                falcon_md.selected_ds_qlen = falcon_md.task_resub_hdr.qlen_2 + 1;
                            }
                        }
                        @stage(4) {
                            update_queue_len_list_1.execute(hdr.falcon.dst_id);
                            update_queue_len_list_2.execute(hdr.falcon.dst_id);
                        }
                        @stage(7) {
                            //reset_deferred_queue_len_list_1.execute(hdr.falcon.dst_id); // Just updated the queue_len_list so write 0 on deferred reg
                        }
                        @stage(8) {
                            //reset_deferred_queue_len_list_2.execute(hdr.falcon.dst_id);
                        }
                    } else {
                        /**Stage 0
                         * get_worker_start_idx
                         * queue_len_unit
                         Registers:
                         * idle_count
                         * linked_sq_sched
                        */
                        get_worker_start_idx(); // Get start index of workers for this vcluster

                        /**Stage 1
                         * get_idle_index, dep: get_worker_start_idx @st0, idle_count @st 0
                         * get_cluster_num_valid
                         * gen_random_workers_16
                         Registers:
                         * aggregate_queue_len, dep: queue_len_unit @st0
                         * iq_len_1
                         * probed_id
                        */
                        // INFO: Compiler bug, if calculate the index for reg action here, compiler complains but if in action its okay!
                        @stage(1){
                            get_cluster_num_valid.apply();
                            gen_random_workers_16();
                        }
                        
                        /** Stage 2
                         * get_curr_idle_index, dep: get_idle_index() @st1
                         * compare_spine_iq_len
                         * adjust_random_range
                         Registers:
                         * All of the worker qlen related regs, deps: resource limit of prev stage  
                        */
                        @stage(2) {
                            falcon_md.mirror_dst_id = hdr.falcon.dst_id; // We want the original packet to reach its destination
                            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                                adjust_random_range_ds.apply(); // move the random indexes to be in range of num workers in rack
                            }
                        } 
                        /** Stage 3
                         * Register:
                         * idle_list, dep: idle_count @st0, get_idle_index() @st 1, get_curr_idle_index() @st 2
                        */ 
                        @stage(3) {
                            if(hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {    
                                offset_random_ids();
                            } 
                        } 
                        
                        /** Stage 4
                         * 
                        */
                        @stage(4) {
                            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                                falcon_md.random_ds_qlen_1 = read_queue_len_list_1.execute(falcon_md.random_id_1);
                                falcon_md.random_ds_qlen_2 = read_queue_len_list_2.execute(falcon_md.random_id_2);
                            } else if(hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                                write_queue_len_list_1.execute(hdr.falcon.src_id);
                                write_queue_len_list_2.execute(hdr.falcon.src_id);
                            } 
                        }

                        /** Stage 5
                         * 
                        */
                        @stage(5){
                        // packet is resubmitted
                            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                                compare_queue_len();
                                get_larger_queue_len();
                            }
                        }

                        /* Stage 6
                         *
                        */
                        @stage(6) {
                            // packet is in first pass
                            calculate_queue_len_diff();
                            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                                if (falcon_md.selected_ds_qlen == falcon_md.random_ds_qlen_1) {
                                    hdr.falcon.dst_id = falcon_md.random_id_1;
                                    falcon_md.task_resub_hdr.ds_index_2 = falcon_md.random_id_2;
                                } else {
                                    hdr.falcon.dst_id = falcon_md.random_id_2;
                                    falcon_md.task_resub_hdr.ds_index_2 = falcon_md.random_id_1;
                                }
                            } 
                        }

                        @stage(7) {
                            if (hdr.falcon.pkt_type==PKT_TYPE_TASK_DONE){
                                //reset_deferred_queue_len_list_1.execute(hdr.falcon.src_id); // Just updated the queue_len_list so write 0 on deferred reg
                            } else if(hdr.falcon.pkt_type==PKT_TYPE_NEW_TASK) {
                                if (falcon_md.random_id_2 != falcon_md.random_id_1) {
                                    //falcon_md.task_resub_hdr.qlen_1 = check_deferred_queue_len_list_1.execute(hdr.falcon.dst_id); // Returns QL[dst_id] + Deferred[dst_id]
                                    falcon_md.task_resub_hdr.ds_index_1 = hdr.falcon.dst_id;
                                } else { // In case two samples point to the same cell, we do not need to resubmit just increment deferred list
                                    //inc_deferred_queue_len_list_1.execute(hdr.falcon.dst_id);
                                }
                            }
                        }

                        @stage(8){
                            if (hdr.falcon.pkt_type==PKT_TYPE_TASK_DONE){
                                //reset_deferred_queue_len_list_2.execute(hdr.falcon.src_id); // Just updated the queue_len_list so write 0 on deferred reg
                            } else if(hdr.falcon.pkt_type==PKT_TYPE_NEW_TASK) {
                                if(falcon_md.task_resub_hdr.qlen_1 == 0) { // This return value means that we do not need to check deffered qlens, difference between samples were large enough that our decision is still valid
                                    //inc_deferred_queue_len_list_2.execute(hdr.falcon.dst_id); // increment the second copy to be consistent with first one
                                } else { // This means our decision might be invalid, need to check the deffered queue lens and resubmit
                                    ig_intr_dprsr_md.resubmit_type = RESUBMIT_TYPE_NEW_TASK;
                                    // falcon_md.task_resub_hdr.qlen_2 = read_deferred_queue_len_list_2.execute(falcon_md.task_resub_hdr.ds_index_2);
                                }
                            }
                        }
                    }
                    forward_falcon_switch_dst.apply();
                    
                }  else if (hdr.ipv4.isValid()) { // Regular switching procedure
                    // TODO: Not ported the ip matching tables for now, do we need them?
                    _drop();
                } else {
                    _drop();
                }
            }
        }

control CentralizedIngressDeparser(
        packet_out pkt,
        inout falcon_header_t hdr,
        in falcon_metadata_t falcon_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {
         
    Mirror() mirror;
    Resubmit() resubmit;

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
            mirror.emit<empty_t>((MirrorId_t) falcon_md.mirror_dst_id, {}); 
        }  else if (ig_intr_dprsr_md.mirror_type == MIRROR_TYPE_NEW_TASK) {

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
parser CentralizedEgressParser(
        packet_in pkt,
        out falcon_header_t hdr,
        out eg_metadata_t eg_md,
        out egress_intrinsic_metadata_t eg_intr_md) {
    state start {
        pkt.extract(eg_intr_md);
        transition accept;
    }
}

control CentralizedEgressDeparser(
        packet_out pkt,
        inout falcon_header_t hdr,
        in eg_metadata_t eg_md,
        in egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md) {
    apply {}
}

control CentralizedEgress(
        inout falcon_header_t hdr,
        inout eg_metadata_t eg_md,
        in egress_intrinsic_metadata_t eg_intr_md,
        in egress_intrinsic_metadata_from_parser_t eg_intr_md_from_prsr,
        inout egress_intrinsic_metadata_for_deparser_t ig_intr_dprs_md,
        inout egress_intrinsic_metadata_for_output_port_t eg_intr_oport_md) {
    apply {}
}