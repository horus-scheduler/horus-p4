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
            Register<bit<16>, _>(MAX_VCLUSTERS) idle_count; // Stores idle count for each vcluster
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_and_inc_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value; // Retruns val before modificaiton
                    value = value + 1;
                }
            };
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_and_dec_idle_count = { 
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value; // Retruns val before modificaiton
                    value = value - 1;
                }
            };
            
            Register<queue_len_t, _>(1024) queue_len_list; // List of queue lens for all vclusters
            RegisterAction<bit<8>, _, bit<8>>(queue_len_list) decrement_queue_len = {
                void apply(inout bit<8> value, out bit<8> rv) {
                    value = value - falcon_md.queue_len_unit;
                    rv = value;
                }
            };
            Register<queue_len_t, _>(MAX_VCLUSTERS) aggregate_queue_len_list; // One for each vcluster
            RegisterAction<bit<8>, _, bit<8>>(aggregate_queue_len_list) decrement_aggregate_queue_len = {
                void apply(inout bit<8> value, out bit<8> rv) {
                    value = value - falcon_md.queue_len_unit;
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
            
            action get_worker_start_idx () {
                falcon_md.cluster_worker_start_idx = (bit <16>) (hdr.falcon.cluster_id * MAX_WORKERS_PER_CLUSTER);
            }

            action get_idle_index () {
                falcon_md.idle_worker_index = falcon_md.cluster_worker_start_idx + (bit <16>) falcon_md.cluster_idle_count;
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

            apply {
                if (hdr.falcon.isValid()) {  // Falcon packet
                    get_worker_start_idx(); // Get start index of workers for this vcluster
                    falcon_md.linked_sq_id = read_linked_sq.execute(hdr.falcon.cluster_id); // Get ID of the Spine that the leaf reports to
                    set_queue_len_unit.apply();
                    if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                        // TODO: Do this in server agent to save computation resource at switch (send adjust index as src_id)
                        get_worker_index();
                        decrement_queue_len.execute(falcon_md.worker_index);
                        falcon_md.aggregate_queue_len = decrement_aggregate_queue_len.execute(hdr.falcon.cluster_id);
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
                                forward_falcon_switch_dst.apply();
                            }
                        }
                    }
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