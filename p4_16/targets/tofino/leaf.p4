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

typedef bit<8> queue_len_t;
typedef bit<32> multi_queue_len_t;
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
 *  
 *   The action get_valid_list_s1_w1 uses Register LeafIngress.list_valid_1 but does not use Register LeafIngress.list_valid_2.
 *   The action get_valid_list_s1_w2 uses Register LeafIngress.list_valid_2 but does not use Register LeafIngress.list_valid_1.
 *   The Tofino architecture requires all indirect externs to be addressed with the same expression across all actions they are used in.
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
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_and_inc_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value; // Retruns val before modificaiton
                    if (value < 0xFF) {
                        value = value + 1;
                    }
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_and_dec_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value; // Retruns val before modificaiton
                    if (value > 0) {
                        value = value - 1;
                    }
                }
            };
            
            Register<bit<8>, _>(MAX_VCLUSTERS) list_valid_1; // Indicates which queue_len_list array is valid and should be used
            RegisterAction<bit<8>, _, bit<1>>(list_valid_1) toggle_list_validity_1 = {
                void apply(inout bit<8> value, out bit<1> rv) {
                    if(value==1){
                        value = 0;
                        rv = 1;
                    } else {
                        value = 1;
                        rv=0;
                    }
                }
            };
            RegisterAction<bit<8>, _, bit<1>>(list_valid_1) reset_list_validity_1 = {
                void apply(inout bit<8> value, out bit<1> rv) {
                    rv = 0;
                }
            };
            
            // List of queue lens for all vclusters
            Register<multi_queue_len_t, _>(MAX_VCLUSTERS) queue_len_lo_0; 
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_lo_0) write_queue_len_lo_0 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    value = falcon_md.write_qlen_lo;
                    rv = value;
                }
            };
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_lo_0) read_queue_len_lo_0 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    rv = value;
                }
            };

            Register<multi_queue_len_t, _>(MAX_VCLUSTERS) queue_len_lo_1; 
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_lo_1) write_queue_len_lo_1 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    value = falcon_md.write_qlen_lo;
                    rv = value;
                }
            };
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_lo_1) read_queue_len_lo_1 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    rv = value;
                }
            };
            
            Register<multi_queue_len_t, _>(MAX_VCLUSTERS) queue_len_hi_0; 
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_hi_0) write_queue_len_hi_0 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    value = falcon_md.write_qlen_hi;
                    rv = value;
                }
            };
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_hi_0) inc_queue_len_hi_0 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    value = value + 1;
                    rv = value;
                }
            };
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_hi_0) read_queue_len_hi_0 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    rv = value;
                }
            };
            
            Register<multi_queue_len_t, _>(MAX_VCLUSTERS) queue_len_hi_1; 
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_hi_1) write_queue_len_hi_1 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    value = falcon_md.write_qlen_hi;
                    rv = value;
                }
            };
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_hi_1) inc_queue_len_hi_1 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    value = value + 1;
                    rv = value;
                }
            };
            RegisterAction<multi_queue_len_t, _, multi_queue_len_t>(queue_len_hi_1) read_queue_len_hi_1 = {
                void apply(inout multi_queue_len_t value, out multi_queue_len_t rv) {
                    rv = value;
                }
            };

            Register<queue_len_t, _>(MAX_VCLUSTERS) aggregate_queue_len_list; // One for each vcluster
            RegisterAction<bit<8>, _, bit<8>>(aggregate_queue_len_list) dec_aggregate_queue_len = {
                void apply(inout bit<8> value, out bit<8> rv) {
                    value = value - falcon_md.queue_len_unit;
                    rv = value;
                }
            };
            RegisterAction<bit<8>, _, bit<8>>(aggregate_queue_len_list) inc_aggregate_queue_len = {
                void apply(inout bit<8> value, out bit<8> rv) {
                    value = value + falcon_md.queue_len_unit;
                    rv = value;
                }
            };

            Register<switch_id_t, _>(MAX_VCLUSTERS) linked_iq_sched; // Spine that ToR has sent last IdleSignal (1 for each vcluster).
            Register<switch_id_t, _>(MAX_VCLUSTERS) linked_sq_sched; // Spine that ToR has sent last QueueSignal (1 for each vcluster).
            RegisterAction<bit<16>, _, bit<16>>(linked_sq_sched) read_linked_sq  = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value;
                }
            };
            // Below are registers to hold state in middle of probing Idle list proceess. 
            // So we can compare them when second switch responds.
            Register<queue_len_t, _>(MAX_VCLUSTERS) spine_iq_len_1; // Length of Idle list for first probed spine (1 for each vcluster).
            Register<switch_id_t, _>(MAX_VCLUSTERS) spine_probed_id; // ID of the first probed spine (1 for each vcluster)

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

            action get_worker_index () {
                falcon_md.worker_index = (bit<16>) hdr.falcon.src_id + falcon_md.cluster_worker_start_idx;
            }

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
                ig_intr_tm_md.mcast_grp_b = falcon_md.rand_probe_group; // Different out ports for level 2 randomly generated
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
            

            action gen_random_worker_id_16() {
                falcon_md.random_downstream_id_1 = (bit<16>) random_worker_id_16.get();
                falcon_md.random_downstream_id_2 = (bit<16>) random_worker_id_16.get();
            }
            
            action gen_random_worker_id_8() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 8;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 8;
            }

            action gen_random_worker_id_4() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 12;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 12;
            }

            action gen_random_worker_id_2() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 14;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 14;
            }

            action gen_random_worker_id_1() {
                falcon_md.random_downstream_id_1 = falcon_md.random_downstream_id_1 >> 15;
                falcon_md.random_downstream_id_2 = falcon_md.random_downstream_id_2 >> 15;
            }
            
            action compare_queue_len() {
                falcon_md.selected_worker_qlen = min(falcon_md.random_worker_qlen_1, falcon_md.random_worker_qlen_2);
            }

            action act_random1_qlen1() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_lo[7:0];
            }
            action act_random1_qlen2() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_lo[15:8];
            }
            action act_random1_qlen3() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_lo[23:16];
            }
            action act_random1_qlen4() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_lo[31:24];
            }
            action act_random1_qlen5() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_hi[7:0];
            }
            action act_random1_qlen6() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_hi[15:8];
            }
            action act_random1_qlen7() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_hi[23:16];
            }
            action act_random1_qlen8() {
                falcon_md.random_worker_qlen_1 = falcon_md.worker_qlen_hi[31:24];
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

            table assign_qlen_random1_copy {
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
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_lo[7:0];
            }
            action act_random2_qlen2() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_lo[15:8];
            }
            action act_random2_qlen3() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_lo[23:16];
            }
            action act_random2_qlen4() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_lo[31:24];
            }
            action act_random2_qlen5() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_hi[7:0];
            }
            action act_random2_qlen6() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_hi[15:8];
            }
            action act_random2_qlen7() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_hi[23:16];
            }
            action act_random2_qlen8() {
                falcon_md.random_worker_qlen_2 = falcon_md.worker_qlen_hi[31:24];
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

            action act_inc_1_qlen1() {
                falcon_md.write_qlen_lo = falcon_md.worker_qlen_lo + (32w1);
            }
            action act_inc_1_qlen2() {
                falcon_md.write_qlen_lo = falcon_md.worker_qlen_lo + (32w256);
            }
            action act_inc_1_qlen3() {
                falcon_md.write_qlen_lo = falcon_md.worker_qlen_lo + (32w65536);
            }
            action act_inc_1_qlen4() {
                falcon_md.write_qlen_lo = falcon_md.worker_qlen_lo + (32w16777216);
            }
            table inc_selected_qlen {
                key = {
                    hdr.falcon.dst_id : exact;
                }
                actions = {
                    act_inc_1_qlen1;
                    act_inc_1_qlen2;
                    act_inc_1_qlen3;
                    act_inc_1_qlen4;
                    NoAction;
                }
                size = 16;
                default_action = NoAction;
            }
            
            action read_worker_lo_0 () {
                falcon_md.worker_qlen_lo = read_queue_len_lo_0.execute(hdr.falcon.cluster_id);
            }
            action read_worker_lo_1 () {
                falcon_md.worker_qlen_lo = read_queue_len_lo_1.execute(hdr.falcon.cluster_id);
            }
            action read_worker_hi_0 () {
                falcon_md.worker_qlen_hi = read_queue_len_hi_0.execute(hdr.falcon.cluster_id);
            }
            action read_worker_hi_1 () {
                falcon_md.worker_qlen_hi = read_queue_len_hi_1.execute(hdr.falcon.cluster_id);
            }
            action write_worker_lo_0() {
                write_queue_len_lo_0.execute(hdr.falcon.cluster_id);
            }
            action write_worker_lo_1() {
                write_queue_len_lo_1.execute(hdr.falcon.cluster_id);
            }
            action write_worker_hi_0() {
                write_queue_len_hi_0.execute(hdr.falcon.cluster_id);
            }
            action write_worker_hi_1() {
                write_queue_len_hi_1.execute(hdr.falcon.cluster_id);
            }
            apply {
                if (hdr.falcon.isValid()) {  // Falcon packet
                    get_worker_start_idx(); // Get start index of workers for this vcluster
                    falcon_md.linked_sq_id = read_linked_sq.execute(hdr.falcon.cluster_id); // Get ID of the Spine that the leaf reports to
                    set_queue_len_unit.apply();
                    if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                        // TODO: Do this in server agent to save computation resource at switch (send adjust index as src_id)
                        get_worker_index();
                        @stage(4) {
                            reset_list_validity_1.execute(hdr.falcon.cluster_id);
                        }
                        @stage(5){
                            write_worker_lo_1();
                        }
                        @stage(6){
                            write_worker_hi_1();
                        }

                        falcon_md.aggregate_queue_len = dec_aggregate_queue_len.execute(hdr.falcon.cluster_id);
                        if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) {
                            falcon_md.cluster_idle_count = read_and_inc_idle_count.execute(hdr.falcon.cluster_id); // Read last idle count for vcluster
                            get_idle_index (); // Get the index of idle worker in idle list (pointes to next available index)
                            add_to_idle_list.execute(falcon_md.idle_worker_index); /// Add src_id to Idle list.
                            if (falcon_md.cluster_idle_count == 1) { // Leaf just became idle so needs to announce to the spine layer
                                hdr.falcon.pkt_type = PKT_TYPE_PROBE_IDLE_QUEUE; // Change packet type to probe
                                /* 
                                 TODO: Check details of ig_intr_tm_md.mcast_grp_a, mcast_grp_b
                                 TODO: How to route packet to spines in other pods that are multi hops away?
                                */
                                falcon_md.rand_probe_group = (bit<16>)random_probe_group.get(); 
                                gen_random_probe_group();
                            }
                        }
                        if (falcon_md.linked_sq_id != 0xFF) {
                            // Set different mirror types for different headers if needed
                            ig_intr_dprsr_md.mirror_type = MIRROR_TYPE_WORKER_RESPONSE; 
                            /* 
                            Desired behaviour: Mirror premitive (emit invoked in ingrdeparser) will send the original response
                            Here we modify the original packet and send it as a ctrl pkt to the linked spine.
                            TODO: Might not work as we expect.
                            */
                            hdr.falcon.pkt_type = PKT_TYPE_QUEUE_SIGNAL;
                            hdr.falcon.qlen = falcon_md.aggregate_queue_len;
                            hdr.falcon.dst_id = falcon_md.linked_sq_id;
                        }
                        
                    } else if (hdr.falcon.pkt_type == PKT_TYPE_NEW_TASK) {
                        falcon_md.cluster_idle_count = read_and_dec_idle_count.execute(hdr.falcon.cluster_id); // Read last idle count for vcluster
                        inc_aggregate_queue_len.execute(hdr.falcon.cluster_id);
                        if (falcon_md.cluster_idle_count > 0) {
                            get_idle_index();
                            get_curr_idle_index(); // Decrements the idle index so we read the correct index
                            hdr.falcon.dst_id = read_idle_list.execute(falcon_md.idle_worker_index);
                        } else {
                            get_cluster_num_valid_ds.apply(); // Get num workers in this rack for this vcluster? Configured by ctrl plane.
                            gen_random_worker_id_16();    
                            if (falcon_md.cluster_num_valid_ds == 8) {
                                gen_random_worker_id_8();
                            } else if (falcon_md.cluster_num_valid_ds == 4) {
                                gen_random_worker_id_4();
                            } else if (falcon_md.cluster_num_valid_ds == 2) {
                                gen_random_worker_id_2();
                            } else if (falcon_md.cluster_num_valid_ds == 1) {
                                gen_random_worker_id_1();
                            }
                            
                            bit <1> valid_list_for_worker_1;
                            @stage(4){
                                valid_list_for_worker_1 = toggle_list_validity_1.execute(hdr.falcon.cluster_id);
                            }

                            if (valid_list_for_worker_1 == 0) {
                                    read_worker_lo_0();
                                    read_worker_hi_0();
                                    assign_qlen_random1.apply();
                                    assign_qlen_random2.apply();
                                    compare_queue_len();
                                    if(falcon_md.selected_worker_qlen == falcon_md.random_worker_qlen_1) {
                                        hdr.falcon.dst_id = falcon_md.random_downstream_id_1;
                                    } else {
                                        hdr.falcon.dst_id = falcon_md.random_downstream_id_2;
                                    }
                                    inc_selected_qlen.apply();
                                    // if(hdr.falcon.dst_id==1){
                                    //     falcon_md.worker_qlen_lo = falcon_md.worker_qlen_lo + falcon_md.queue_len_unit;
                                    // } else if(hdr.falcon.dst_id==2) {
                                    //     falcon_md.worker_qlen2 = falcon_md.worker_qlen_hi + falcon_md.queue_len_unit;
                                    // }
                                    @stage(5){
                                        write_worker_lo_1();
                                    }
                                    @stage(6){
                                        write_worker_hi_1();
                                    }
                            } else {
                                    read_worker_lo_1();
                                    read_worker_hi_1();
                                    assign_qlen_random1_copy.apply();
                                    // assign_qlen_random2.apply();
                                    // compare_queue_len();
                                    // if(falcon_md.selected_worker_qlen == falcon_md.random_worker_qlen_1) {
                                    //     hdr.falcon.dst_id = falcon_md.random_downstream_id_1;
                                    // } else {
                                    //     hdr.falcon.dst_id = falcon_md.random_downstream_id_2;
                                    // }
                                    // if(hdr.falcon.dst_id==1){
                                    //     falcon_md.worker_qlen_lo = falcon_md.worker_qlen_lo + falcon_md.queue_len_unit;
                                    // } else if(hdr.falcon.dst_id==2) {
                                    //     falcon_md.worker_qlen2 = falcon_md.worker_qlen_hi + falcon_md.queue_len_unit;
                                    // }
                                    @stage(5){
                                    write_worker_lo_0();
                                    }
                                    @stage(6){
                                    write_worker_hi_0();
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