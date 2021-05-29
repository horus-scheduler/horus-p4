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
        RegisterAction<bit<16>, _, bit<16>>(queue_signal_count) read_and_dec_queue_signal_count = { 
            void apply(inout bit<16> value, out bit<16> rv) {
                if (value > 0) { 
                    rv = value;
                    value = value - 1;
                }
            }
        };

    Register<queue_len_t, _>(MAX_LINKED_LEAFS) queue_len_list_1; // List of queue lens for all vclusters
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
    Register<queue_len_t, _>(MAX_LINKED_LEAFS) queue_len_list_2; // List of queue lens for all vclusters
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

    Register<leaf_id_t, _>(MAX_LINKED_LEAFS) lid_list; // List of leaf IDs that we are tracking their queue signal (so we can select them when comparing the queue_len_list)
        RegisterAction<bit<16>, _, bit<16>>(idle_list) add_to_lid_list = {
            void apply(inout bit<16> value, out bit<16> rv) {
                value = hdr.falcon.src_id;
                rv = value;
            }
        };
        RegisterAction<bit<16>, _, bit<16>>(idle_list) read_lid_list = {
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
    action get_idle_index () {
        falcon_md.idle_ds_index = falcon_md.cluster_ds_start_idx + (bit <16>) falcon_md.cluster_idle_count;
    }
    action get_curr_idle_index() {
        falcon_md.idle_ds_index = falcon_md.idle_ds_index -1;
    }
    action gen_random_leaf_index_16() {
        falcon_md.random_downstream_id_1 = (bit<16>) random_ds_id.get();
        falcon_md.random_downstream_id_2 = (bit<16>) random_ds_id.get();
    }
    action adjust_random_leaf_index_8() {
        falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 8;
        falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 8;
    }

    action adjust_random_leaf_index_4() {
        falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 12;
        falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 12;
    }

    action adjust_random_leaf_index_2() {
        falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 14;
        falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 14;
    }

    action adjust_random_leaf_index_1() {
        falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 15;
        falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 15;
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
            get_leaf_start_idx ();
            get_cluster_num_valid_leafs.apply();
            gen_random_leaf_index_16();
            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK || hdr.falcon.pkt_type == PKT_TYPE_PROBE_IDLE_QUEUE) {
                falcon_md.cluster_idle_count = read_idle_count.execute(hdr.falcon.cluster_id); // Get num_idles
                falcon_md.cluster_num_valid_queue_signals = read_queue_signal_count.execute(hdr.falcon.cluster_id); // How many queue signals available
            }

            /** Stage 1
             * Registers:
             *
             * Tables:
             * get_idle_index(), deps: reg idle_count (stage 0)
            */
            get_idle_index();
            if (falcon_md.cluster_num_valid_queue_signals > 1) {
                adjust_random_range_sq_leafs.apply(); // We want to select a random worker from all workers
            } else {
                adjust_random_range_all_leafs.apply(); // We want to select a random worker from available qlen signals
            }

            /** Stage 2
             * Registers:
             *
             * Tables:
             * get_curr_idle_index(), deps: reg get_idle_index (stage 1)
            */
            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                get_curr_idle_index(); // decrement the index so we read the correct idle leaf ID
                if (falcon_md.cluster_num_valid_queue_signals > 1) { // Select least loaded from 2 samples
                    falcon_md.random_ds_qlen_1 = read_queue_len_list_1.execute(falcon_md.random_downstream_id_1);
                    falcon_md.random_ds_qlen_1 = read_queue_len_list_2.execute(falcon_md.random_downstream_id_1);
                } else { // Select a random leaf for now since we don't have enough information

                }
                if (falcon_md.cluster_num_valid_ds < MAX_LINKED_LEAFS) {

                }
            }

            /** Stage 3
             * Registers:
             * idle_list, deps: get_curr_idle_index  (stage 2)
             * Tables:
             *  
            */
            if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                if (falcon_md.cluster_idle_count > 0) { // Spine knows about some idle leafs 
                    hdr.falcon.dst_id = read_idle_list.execute(falcon_md.idle_ds_index);
                } else if(falcon_md.cluster_num_valid_queue_signals > 1) {
                    
                } else if(falcon_md.cluster_num_valid_queue_signals < 2) {

                }
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
        if (ig_intr_dprsr_md.resubmit_type == RESUBMIT_TYPE_NEW_TASK) {
            resubmit.emit(falcon_md.task_resub_hdr);
        }
        pkt.emit(hdr.ethernet);
        pkt.emit(hdr.ipv4);
        pkt.emit(hdr.udp);
        pkt.emit(hdr.falcon);
    }
}
