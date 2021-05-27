import logging

from ptf import config
import ptf.testutils as testutils
from bfruntime_client_base_tests import BfRuntimeTest
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as client
import random
from pkts import *

logger = logging.getLogger('Test')
if not len(logger.handlers):
    logger.addHandler(logging.StreamHandler())

num_pipes = int(testutils.test_param_get('num_pipes'))
pipes = list(range(num_pipes))

swports = []
for device, port, ifname in config["interfaces"]:
    pipe = port >> 7
    if pipe in pipes:
        swports.append(port)
swports.sort()

SAMPLE_ETH_SRC = "AA:BB:CC:DD:EE"
SAMPLE_ETH_DST = "EE:DD:CC:BB:AA"
SAMPLE_IP_SRC = "192.168.0.10"
SAMPLE_IP_DST = "192.168.0.11"

TEST_VCLUSTER_ID = 0

def VerifyReadRegisters(self, register_name, pipe_id, expected_register_value, data_dict):
    # since the table is symmetric and exists only in stage 0, we know that the response data is going to have
    # 8 data fields (2 (hi and lo) * 4 (num pipes) * 1 (num_stages)). bfrt_server returns all (4) register values
    # corresponding to one field id followed by all (4) register values corresponding to the other field id

    value = data_dict[register_name][pipe_id]
    assert value == expected_register_value, "Register field didn't match with the read value." \
                                             " Expected Value (%s) : Read value (%s)" % (
                                             str(expected_register_value), str(value))

class ScheduleTaskIdleState(BfRuntimeTest):
    def setUp(self):
        client_id = 0
        p4_name = "falcon"
        self.target = client.Target(device_id=0, pipe_id=0xffff) ## Here pipe_id  0xffff it mean All Pipes ? TODO: how to set spcific pipe?
        self.tables = []
        BfRuntimeTest.setUp(self, client_id, p4_name)
        
    def cleanup(self):
        """ Delete all the stored entries. """
        print("\n")
        print("Table Cleanup:")
        print("==============")
        try:
            for t in reversed(self.tables):
                print(("  Clearing Table {}".format(t.info.name_get())))
                t.entry_del(self.target)
        except Exception as e:
            print(("Error cleaning up: {}".format(e)))
    
    def init_tables(self):
        bfrt_info = self.interface.bfrt_info_get("falcon")
        self.register_idle_count = bfrt_info.table_get("LeafIngress.idle_count")
        self.register_idle_list = bfrt_info.table_get("LeafIngress.idle_list")
        self.forward_falcon_switch_dst = bfrt_info.table_get("LeafIngress.forward_falcon_switch_dst")
        self.forward_falcon_switch_dst.info.key_field_annotation_add("hdr.falcon.dst_id", "wid")
        self.tables.append(self.register_idle_count)
        self.tables.append(self.register_idle_list)
        self.tables.append(self.forward_falcon_switch_dst)

    def runTest(self):
        print(swports)
        initial_idle_count = 4
        initial_idle_list = [15, 11, 12, 17]
        wid_port_mapping = {11:1, 12: 2, 13:3, 14: 4, 15:5, 16: 6, 17:7, 18: 8}

        pipe_id = 0
        num_pipes = int(testutils.test_param_get('num_pipes')) # Currently not used, but useful in multi-switch (different pipes) tests

        # udp_pkt = testutils.simple_udp_packet(pktlen=0,
        #                         eth_dst=SAMPLE_ETH_SRC,
        #                         eth_src=SAMPLE_ETH_DST,
        #                         ip_dst=SAMPLE_IP_DST,
        #                         ip_src=SAMPLE_IP_SRC,
        #                         udp_sport=1234,
        #                         udp_dport=1234)
       

        

        self.init_tables()
        self.cleanup()

        logger.info("Inserting entry in idle_count register with value = %s ", str(initial_idle_count))

        self.register_idle_count.entry_add(
            self.target,
            [self.register_idle_count.make_key([client.KeyTuple('$REGISTER_INDEX', TEST_VCLUSTER_ID)])],
            [self.register_idle_count.make_data([client.DataTuple('LeafIngress.idle_count.f1', initial_idle_count)])])

        logger.info("Reading back the idle_count register")
        resp = self.register_idle_count.entry_get(
            self.target,
            [self.register_idle_count.make_key([client.KeyTuple('$REGISTER_INDEX', TEST_VCLUSTER_ID)])],
            {"from_hw": True})

        data_dict = next(resp)[0].to_dict()
        print(data_dict)
        logger.info("Verifying read back register values")
        VerifyReadRegisters(self, "LeafIngress.idle_count.f1", pipe_id, initial_idle_count, data_dict)
        
        logger.info("Inserting entries in idle_list register with value = %s ", str(initial_idle_list))

        for i in range(initial_idle_count):
            self.register_idle_list.entry_add(
                self.target,
                [self.register_idle_list.make_key([client.KeyTuple('$REGISTER_INDEX', i)])],
                [self.register_idle_list.make_data([client.DataTuple('LeafIngress.idle_list.f1', initial_idle_list[i])])])

            logger.info("Reading back the idle_list register")
            resp = self.register_idle_list.entry_get(
                self.target,
                [self.register_idle_list.make_key([client.KeyTuple('$REGISTER_INDEX', i)])],
                {"from_hw": True})

            data_dict = next(resp)[0].to_dict()
            print(data_dict)
            logger.info("Verifying read back register values")
            VerifyReadRegisters(self, "LeafIngress.idle_list.f1", pipe_id, initial_idle_list[i], data_dict)

        logger.info("********* Populating Table Entires *********")
        for wid in wid_port_mapping.keys():
            self.forward_falcon_switch_dst.entry_add(
                self.target,
                [self.forward_falcon_switch_dst.make_key([client.KeyTuple('hdr.falcon.dst_id', wid)])],
                [self.forward_falcon_switch_dst.make_data([client.DataTuple('port', wid_port_mapping[wid])],
                                             'LeafIngress.act_forward_falcon')]
            )
        logger.info("Inserted entries in forward_falcon_switch_dst table with key-values = %s ", str(wid_port_mapping))

        
        logger.info("********* Sending NEW_TASK packets, Testing scheduling on idle workers *********")
        eth_kwargs = {
        'src_mac': SAMPLE_ETH_SRC,
        'dst_mac': SAMPLE_ETH_DST
        }
        for i in range(initial_idle_count):
            idle_pointer_stack = initial_idle_count - i - 1 # This is the expected stack pointer in the switch (iterates the list from the last element)
            ig_port = swports[random.randint(9, 15)] # port connected to spine
            eg_port = swports[wid_port_mapping[initial_idle_list[idle_pointer_stack]]]
            src_id = random.randint(1, 255)
            dst_id = random.randint(1, 255)
            
            new_task_packet = make_falcon_task_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=random.randint(1, 255), pkt_len=0, seq_num=0x10+i, **eth_kwargs)
            expected_packet = make_falcon_task_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=initial_idle_list[idle_pointer_stack], pkt_len=0, seq_num=0x10+i, **eth_kwargs)
            
            logger.info("Sending task packet on port %d", ig_port)
            testutils.send_packet(self, ig_port, new_task_packet)
            logger.info("Expecting task packet on port %d (IFACE-OUT)", eg_port)
            testutils.verify_packets(self, expected_packet, [eg_port])

