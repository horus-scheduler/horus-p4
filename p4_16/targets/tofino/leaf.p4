#include <core.p4>
#include <tna.p4>

#include "common/headers.p4"
#include "common/util.p4"
#include "headers.p4"
#include "parser.p4"

#define MAX_VCLUSTERS 32
#define MAX_WORKERS_PER_CLUSTER 32

typedef bit<8> queue_len_t;
typedef bit<9> port_id_t;
typedef bit<16> worker_id_t;
typedef bit<16> switch_id_t;
typedef bit<QUEUE_LEN_FIXED_POINT_SIZE> len_fixed_point_t;

/*
 * Notes:
 *  An action can be called directly without a table (from apply{} block)
 *  Here multiple calls to action from the apply{} block is allowed (e.g in different if-else branches)
 *  Limitation: If multiple operations Require multiple stages for a single action. We currently support only single stage actions.
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

            apply {
                if (hdr.falcon.isValid()) {  // Falcon packet
                    get_worker_start_idx(); // Get start index of workers for this vcluster
                    falcon_md.linked_sq_id = read_linked_sq.execute(hdr.falcon.cluster_id); // Get ID of the Spine that the leaf reports to
                    set_queue_len_unit.apply();
                    if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE || hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE) {
                        // TODO: Do this in server agent to save computation resource at switch (send adjust index as src_id)
                        get_worker_index();
                        decrement_queue_len.execute(falcon_md.worker_index);
                        decrement_aggregate_queue_len.execute(hdr.falcon.cluster_id);
                        if (hdr.falcon.pkt_type == PKT_TYPE_TASK_DONE_IDLE) {
                            falcon_md.cluster_idle_count = read_and_inc_idle_count.execute(hdr.falcon.cluster_id); // Read last idle count for vcluster
                            get_idle_index (); // Get the index of idle worker in idle list (pointes to next available index)
                            add_to_idle_list.execute(falcon_md.idle_worker_index);
                            
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
        in falcon_metadata_t ig_md,
        in ingress_intrinsic_metadata_for_deparser_t ig_intr_dprsr_md) {
         
    //Resubmit() resubmit;
    
    apply {        
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