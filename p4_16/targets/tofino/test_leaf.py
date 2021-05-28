import logging

from ptf import config
import ptf.testutils as testutils
from bfruntime_client_base_tests import BfRuntimeTest
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as client
import random
from pkts import *
import os

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

SAMPLE_ETH_SRC = "AA:BB:CC:DD:EE:00"
SAMPLE_ETH_DST = "EE:DD:CC:BB:AA:00"
SAMPLE_IP_SRC = "192.168.0.10"
SAMPLE_IP_DST = "192.168.0.11"
eth_kwargs = {
        'src_mac': SAMPLE_ETH_SRC,
        'dst_mac': SAMPLE_ETH_DST
        }
TEST_VCLUSTER_ID = 0
MAX_VCLUSTER_WORKERS = 32

def VerifyReadRegisters(register_name, pipe_id, expected_register_value, data_dict):
    # since the table is symmetric and exists only in stage 0, we know that the response data is going to have
    # 8 data fields (2 (hi and lo) * 4 (num pipes) * 1 (num_stages)). bfrt_server returns all (4) register values
    # corresponding to one field id followed by all (4) register values corresponding to the other field id

    value = data_dict[register_name][pipe_id]
    assert value == expected_register_value, "Register field didn't match with the read value." \
                                             " Expected Value (%s) : Read value (%s)" % (
                                             str(expected_register_value), str(value))

def register_write(target, register_object, register_name, index, register_value):
        logger.info("Inserting entry in %s register with value = %s ", str(register_name), str(register_value))

        register_object.entry_add(
            target,
            [register_object.make_key([client.KeyTuple('$REGISTER_INDEX', index)])],
            [register_object.make_data([client.DataTuple(register_name, register_value)])])

def test_register_read(target, register_object, register_name, pipe_id, index, expected_register_value):
        logger.info("Reading back %s register", str(register_name))
        resp = register_object.entry_get(
                target,
                [register_object.make_key([client.KeyTuple('$REGISTER_INDEX', index)])],
                {"from_hw": True})
        data_dict = next(resp)[0].to_dict()
        print(data_dict)
        logger.info("Verifying read back register values...")
        VerifyReadRegisters(register_name, pipe_id, expected_register_value, data_dict)

class TestFalconLeaf(BfRuntimeTest):
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
        # Registers
        self.register_idle_count = bfrt_info.table_get("LeafIngress.idle_count")
        self.register_idle_list = bfrt_info.table_get("LeafIngress.idle_list")
        self.register_aggregate_queue_len = bfrt_info.table_get("LeafIngress.aggregate_queue_len_list")
        self.register_linked_sq_sched = bfrt_info.table_get("LeafIngress.linked_sq_sched")
        self.register_linked_iq_sched = bfrt_info.table_get("LeafIngress.linked_iq_sched")
        self.register_queue_len_list_1 = bfrt_info.table_get("LeafIngress.queue_len_list_1")
        self.register_queue_len_list_2 = bfrt_info.table_get("LeafIngress.queue_len_list_2")

        # MA Tables
        self.forward_falcon_switch_dst = bfrt_info.table_get("LeafIngress.forward_falcon_switch_dst")
        self.forward_falcon_switch_dst.info.key_field_annotation_add("hdr.falcon.dst_id", "wid")
        self.set_queue_len_unit = bfrt_info.table_get("LeafIngress.set_queue_len_unit")
        self.set_queue_len_unit.info.key_field_annotation_add("hdr.falcon.local_cluster_id", "vcid")
        self.get_cluster_num_valid_ds = bfrt_info.table_get("LeafIngress.get_cluster_num_valid_ds")
        self.get_cluster_num_valid_ds.info.key_field_annotation_add("hdr.falcon.cluster_id", "vcid")
        self.adjust_random_range = bfrt_info.table_get("LeafIngress.adjust_random_range")
        self.adjust_random_range.info.key_field_annotation_add("falcon_md.cluster_num_valid_ds", "num_valid_ds")

        self.tables.append(self.register_idle_count)
        self.tables.append(self.register_idle_list)
        self.tables.append(self.register_aggregate_queue_len)
        self.tables.append(self.register_linked_sq_sched)
        self.tables.append(self.register_linked_iq_sched)
        self.tables.append(self.register_queue_len_list_1)
        self.tables.append(self.register_queue_len_list_2)

        self.tables.append(self.adjust_random_range)
        self.tables.append(self.forward_falcon_switch_dst)
        self.tables.append(self.set_queue_len_unit)
        self.tables.append(self.get_cluster_num_valid_ds)

    def runTest(self):
        # TODO: fix this, test script does not recognize the exported env variables
        #test_case = os.environ.get('FALCON_TEST_CASE')
        test_case = 'sq'
        logger.info("\n***** Starting Test Case: %s \n", str(test_case))
        
        self.init_tables()
        self.cleanup()

        if test_case == 'idle':# Testing scheduling when idle worker are available
            self.schedule_task_idle_state()
        elif test_case == 'sq':# Testing scheduling when no idle worker is available
            self.schedule_task_sq_state()

    def schedule_task_sq_state(self):
        pipe_id = 0

        initial_idle_count = 0
        initial_idle_list = []
        wid_port_mapping = {0:0, 1:1, 2:2, 3:3, 4:4, 5:4, 6:4, 7:4}

        qlen_unit = 0b00000010
        initial_num_waiting_tasks = 10
        initial_agg_qlen = initial_num_waiting_tasks * qlen_unit 
        
        initial_linked_iq_spine = 0xFFFF # ID of linked spine for Idle link (Invalid = 0xFFFF, since we hav no idle workers)
        initial_linked_sq_spine = 0xFFFF # ID of linked spine for SQ link (Invalid = 0xFFFF, test this later) TODO: test sq report to spine

        intitial_qlen_state = [6, 1]
        num_valid_ds_elements = 1 # num actual workers for this vcluster in this rack

        workers_start_idx = TEST_VCLUSTER_ID * MAX_VCLUSTER_WORKERS
        logger.info("***** Writing registers for initial state  *******")
        register_write(self.target,
                self.register_linked_iq_sched,
                register_name='LeafIngress.linked_iq_sched.f1',
                index=TEST_VCLUSTER_ID,
                register_value=initial_linked_iq_spine)

        register_write(self.target,
                self.register_linked_sq_sched,
                register_name='LeafIngress.linked_sq_sched.f1',
                index=TEST_VCLUSTER_ID,
                register_value=initial_linked_sq_spine)

        register_write(self.target,
                self.register_aggregate_queue_len,
                register_name='LeafIngress.aggregate_queue_len_list.f1',
                index=TEST_VCLUSTER_ID,
                register_value=initial_agg_qlen)

        for i, qlen in enumerate(intitial_qlen_state):
            register_write(self.target,
                    self.register_queue_len_list_1,
                    register_name='LeafIngress.queue_len_list_1.f1',
                    index=workers_start_idx + i,
                    register_value=qlen)
            register_write(self.target,
                    self.register_queue_len_list_2,
                    register_name='LeafIngress.queue_len_list_2.f1',
                    index=workers_start_idx + i,
                    register_value=qlen)
        
        logger.info("********* Populating Table Entires *********")
        
        # TODO: can we add constant entrires for this table in .p4 file?
        self.adjust_random_range.entry_add(
                self.target,
                [self.adjust_random_range.make_key([client.KeyTuple('falcon_md.cluster_num_valid_ds', 1)])],
                [self.adjust_random_range.make_data([], 'LeafIngress.adjust_random_worker_range_1')]
            )

        # Insert port mapping for workers
        for wid in wid_port_mapping.keys():
            self.forward_falcon_switch_dst.entry_add(
                self.target,
                [self.forward_falcon_switch_dst.make_key([client.KeyTuple('hdr.falcon.dst_id', wid)])],
                [self.forward_falcon_switch_dst.make_data([client.DataTuple('port', wid_port_mapping[wid])],
                                             'LeafIngress.act_forward_falcon')]
            )
        logger.info("Inserted entries in forward_falcon_switch_dst table with key-values = %s ", str(wid_port_mapping))

        # Insert qlen unit entries
        self.set_queue_len_unit.entry_add(
                self.target,
                [self.set_queue_len_unit.make_key([client.KeyTuple('hdr.falcon.local_cluster_id', TEST_VCLUSTER_ID)])],
                [self.set_queue_len_unit.make_data([client.DataTuple('cluster_unit', qlen_unit)],
                                             'LeafIngress.act_set_queue_len_unit')]
            )

        # Insert num_valid to set actual num workers for this vcluster (in this rack)
        self.get_cluster_num_valid_ds.entry_add(
                self.target,
                [self.get_cluster_num_valid_ds.make_key([client.KeyTuple('hdr.falcon.cluster_id', TEST_VCLUSTER_ID)])],
                [self.get_cluster_num_valid_ds.make_data([client.DataTuple('num_ds_elements', num_valid_ds_elements)],
                                             'LeafIngress.act_get_cluster_num_valid_ds')]
            )

        logger.info("********* Sending NEW_TASK packets, Testing scheduling on busy workers *********")
        
        expected_agg_qlen = initial_agg_qlen
        for i in range(2):
            test_register_read(self.target, #Idle count should stay at 0
                self.register_idle_count,
                'LeafIngress.idle_count.f1',
                pipe_id,
                TEST_VCLUSTER_ID,
                0)

            ig_port = swports[random.randint(9, 15)] # port connected to spine
            src_id = random.randint(1, 255)
            dst_id = random.randint(1, 255)

            new_task_packet = make_falcon_task_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=random.randint(1, 255), pkt_len=0, seq_num=0x10+i, **eth_kwargs)
            expected_packet_0 = make_falcon_task_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=0, pkt_len=0, seq_num=0x10+i, **eth_kwargs)
            expected_packet_1 = make_falcon_task_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=1, pkt_len=0, seq_num=0x10+i, **eth_kwargs)
            logger.info("Sending task packet on port %d", ig_port)
            testutils.send_packet(self, ig_port, new_task_packet)
            # Can't expect the packet since random sampling happens inside the switch 
            #logger.info("Expecting task packet to be forwarded on port %d (IFACE-OUT)", eg_port)

            #testutils.verify_packets(self, expected_packet, [eg_port])
            #testutils.verify_any_packet_any_port(self, [expected_packet_0, expected_packet_1], [0,1])
            
            poll_res = testutils.dp_poll(self)
            print(poll_res)
            out_port = int(poll_res[1])
            
            # Check aggregate queue len is incremented
            expected_agg_qlen += qlen_unit
            test_register_read(self.target,
                self.register_aggregate_queue_len,
                'LeafIngress.aggregate_queue_len_list.f1',
                pipe_id,
                TEST_VCLUSTER_ID,
                expected_agg_qlen)
            intitial_qlen_state[out_port] += 1
            # Check switch internal state about selected qlen is updated
            test_register_read(self.target,
                self.register_queue_len_list_1,
                'LeafIngress.queue_len_list_1.f1',
                pipe_id,
                out_port,
                intitial_qlen_state[out_port])

            test_register_read(self.target,
                self.register_queue_len_list_2,
                'LeafIngress.queue_len_list_2.f1',
                pipe_id,
                out_port,
                intitial_qlen_state[out_port])

    def schedule_task_idle_state(self):
        pipe_id = 0

        initial_idle_count = 4
        initial_idle_list = [15, 11, 12, 17]
        wid_port_mapping = {11:1, 12: 2, 13:3, 14: 4, 15:5, 16: 6, 17:7, 18: 8, 100: 10}

        initial_agg_qlen = 0
        qlen_unit = 0b00000010 # assuming 3bit showing fraction and 5bit decimal: 0.25 (4 workers in this rack)

        initial_linked_iq_spine = 105 # ID of linked spine for Idle link
        initial_linked_sq_spine = 0xFFFF # ID of linked spine for SQ link (Invalid = 0xFFFF, since we are in idle state)
        
        # Scenario when 2 workers finish their task 
        num_task_done = 2

        register_write(self.target,
                self.register_linked_iq_sched,
                register_name='LeafIngress.linked_iq_sched.f1',
                index=TEST_VCLUSTER_ID,
                register_value=initial_linked_iq_spine)

        register_write(self.target,
                self.register_linked_sq_sched,
                register_name='LeafIngress.linked_sq_sched.f1',
                index=TEST_VCLUSTER_ID,
                register_value=initial_linked_sq_spine)

        register_write(self.target,
            self.register_idle_count,
            register_name='LeafIngress.idle_count.f1',
            index=TEST_VCLUSTER_ID,
            register_value=initial_idle_count)
        
        register_write(self.target,
                self.register_aggregate_queue_len,
                register_name='LeafIngress.aggregate_queue_len_list.f1',
                index=TEST_VCLUSTER_ID,
                register_value=initial_agg_qlen)

        # Simply verify the read from hw to check correct values were inserted
        test_register_read(self.target,
            self.register_idle_count,
            'LeafIngress.idle_count.f1',
            pipe_id,
            TEST_VCLUSTER_ID,
            initial_idle_count)

        test_register_read(self.target,
            self.register_aggregate_queue_len,
            'LeafIngress.aggregate_queue_len_list.f1',
            pipe_id,
            TEST_VCLUSTER_ID,
            initial_agg_qlen)

        # Insert idle_list values (wid of idle workers)
        for i in range(initial_idle_count):
            register_write(self.target,
                self.register_idle_list,
                register_name='LeafIngress.idle_list.f1',
                index=i,
                register_value=initial_idle_list[i])

            test_register_read(self.target,
                self.register_idle_list,
                register_name="LeafIngress.idle_list.f1",
                pipe_id=pipe_id,
                index=i,
                expected_register_value=initial_idle_list[i])


        logger.info("********* Populating Table Entires *********")
        # Insert port mapping for workers
        for wid in wid_port_mapping.keys():
            self.forward_falcon_switch_dst.entry_add(
                self.target,
                [self.forward_falcon_switch_dst.make_key([client.KeyTuple('hdr.falcon.dst_id', wid)])],
                [self.forward_falcon_switch_dst.make_data([client.DataTuple('port', wid_port_mapping[wid])],
                                             'LeafIngress.act_forward_falcon')]
            )
        logger.info("Inserted entries in forward_falcon_switch_dst table with key-values = %s ", str(wid_port_mapping))
        
        # Insert qlen unit entries
        self.set_queue_len_unit.entry_add(
                self.target,
                [self.set_queue_len_unit.make_key([client.KeyTuple('hdr.falcon.local_cluster_id', TEST_VCLUSTER_ID)])],
                [self.set_queue_len_unit.make_data([client.DataTuple('cluster_unit', qlen_unit)],
                                             'LeafIngress.act_set_queue_len_unit')]
            )

        logger.info("********* Sending NEW_TASK packets, Testing scheduling on idle workers *********")
        
        expected_agg_qlen = initial_agg_qlen
        for i in range(initial_idle_count):
            test_register_read(self.target,
                self.register_idle_count,
                'LeafIngress.idle_count.f1',
                pipe_id,
                TEST_VCLUSTER_ID,
                initial_idle_count - i)

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
            expected_agg_qlen += qlen_unit
            test_register_read(self.target,
                self.register_aggregate_queue_len,
                'LeafIngress.aggregate_queue_len_list.f1',
                pipe_id,
                TEST_VCLUSTER_ID,
                expected_agg_qlen)
        
        for i in range(num_task_done):
            dst_id = 100 # this will be identifier for client (receiving reply pkt)
            src_id = initial_idle_list[i]
            ig_port = wid_port_mapping[initial_idle_list[i]]
            task_done_idle_packet = make_falcon_task_done_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=dst_id, is_idle=True, pkt_len=0, seq_num=0x10+i, **eth_kwargs)
            expected_packet = make_falcon_task_done_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=dst_id, is_idle=True, pkt_len=0, seq_num=0x10+i, **eth_kwargs)            
            expected_packet_probe_idle = make_falcon_probe_idle_pkt(dst_ip=SAMPLE_IP_DST, cluster_id=TEST_VCLUSTER_ID, local_cluster_id=TEST_VCLUSTER_ID, src_id=src_id, dst_id=dst_id, pkt_len=0, seq_num=0x10+i, **eth_kwargs)            
            logger.info("Sending done_idle packet on port %d", ig_port)
            testutils.send_packet(self, ig_port, task_done_idle_packet)
            
            
            poll_res = testutils.dp_poll(self)
            logger.info("Original response pkt should be forwarded by switch")
            print(poll_res)
            # TODO: Check multiple packets on multiple ports? testutils.verify_any_packet_any_port fails
            logger.info("\n[Note] When first idle pkt is received, swith should send another pkt to spines to probe their IQ len, manually tested in Tofino modle logs\n")
            logger.info("*** Checking the idle_count increase ***")
            test_register_read(self.target,
                self.register_idle_count,
                'LeafIngress.idle_count.f1',
                pipe_id,
                TEST_VCLUSTER_ID,
                i + 1)
            