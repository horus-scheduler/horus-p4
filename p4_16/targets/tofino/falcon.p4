#include "parser.p4"
#include "leaf.p4"
#include "spine.p4"
// Pipeline(FalconIngressParser(),
//          LeafIngress(),
//          LeafIngressDeparser(),
//          FalconEgressParser(),
//          FalconEgress(),
//          FalconEgressDeparser()
//          ) pipe_leaf;

Pipeline(FalconIngressParser(),
         SpineIngress(),
         SpineIngressDeparser(),
         FalconEgressParser(),
         FalconEgress(),
         FalconEgressDeparser()
         ) pipe_spine;

Switch(pipe_spine) main;