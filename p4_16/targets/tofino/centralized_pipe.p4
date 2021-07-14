#include "centralized.p4"
#include "parser.p4"

Pipeline(FalconIngressParser(),
         CentralizedIngress(),
         CentralizedIngressDeparser(),
         CentralizedEgressParser(),
         CentralizedEgress(),
         CentralizedEgressDeparser()
         ) pipe_centralized;

Switch(pipe_centralized) main;