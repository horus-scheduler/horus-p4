
#include <core.p4>
#include <tna.p4>

#include "common/headers.p4"
#include "common/util.p4"
#include "headers.p4"

#define FALCON_PORT 1234

parser FalconIngressParser (
        packet_in pkt,
        out falcon_header_t hdr,
        out falcon_metadata_t ig_md,
        out ingress_intrinsic_metadata_t ig_intr_md) {

    TofinoIngressParser() tofino_parser;

    state start {
        tofino_parser.apply(pkt, ig_intr_md);
        transition parse_ethernet;
    }

    state parse_ethernet {
        pkt.extract(hdr.ethernet);
        transition select (hdr.ethernet.ether_type) {
            ETHERTYPE_IPV4 : parse_ipv4;
            default : reject;
        }
    }

    state parse_ipv4 {
        pkt.extract(hdr.ipv4);
        transition select (hdr.ipv4.protocol) {
            IP_PROTOCOLS_UDP : parse_udp;
            default : reject; 
        }
    }

    state parse_udp {
        pkt.extract(hdr.udp);
        transition select (hdr.udp.dst_port) {
            FALCON_PORT : parse_falcon;
            default: accept;
        }
    }

    state parse_falcon {
        pkt.extract(hdr.falcon);
        transition accept;
    }
}