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
            Register<bit<16>, _>(MAX_VCLUSTERS) idle_count; // Stores idle count for each vcluster
            RegisterAction<bit<16>, _, bit<16>>(idle_count) read_idle_count = {
                void apply(inout bit<16> value, out bit<16> rv) {
                    rv = value;
                }
            };
            Register<queue_len_t, _>(1024) queue_len_list; // List of queue lens for all vclusters
            Register<queue_len_t, _>(MAX_VCLUSTERS) aggregate_queue_len_list; // One for each vcluster

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
            Register<switch_id_t, _>(MAX_VCLUSTERS) spine_probed_id; // ID of the first probed spine ((1 for each vcluster)

            

            

            action get_idle_stat () {
                falcon_md.cluster_worker_start_idx = (bit <16>) (hdr.falcon.cluster_id * MAX_WORKERS_PER_CLUSTER);
            }
            action get_idle_stat_2 () {
                falcon_md.cluster_worker_start_idx = falcon_md.cluster_worker_start_idx + (bit <16>) falcon_md.cluster_idle_count;
                
            }

            action drop() {
                ig_intr_dprsr_md.drop_ctl = 0x1; // Drop packet.
            }

            apply {
                if (hdr.falcon.isValid()) {  // Falcon packet
                    falcon_md.cluster_idle_count = read_idle_count.execute(hdr.falcon.cluster_id);
                    get_idle_stat();
                    get_idle_stat_2 ();
                    falcon_md.cluster_worker_start_idx = falcon_md.cluster_worker_start_idx - 1;
                    falcon_md.linked_sq_id = read_linked_sq.execute(hdr.falcon.cluster_id);

                }  else if (hdr.ipv4.isValid()) { // Regular switching procedure
                    // TODO: Not ported the ip matching tables for now, do we need them?
                    get_idle_stat();
                    drop();
                } else {
                    drop();
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