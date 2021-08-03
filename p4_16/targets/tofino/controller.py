#!/usr/bin/env python
import sys
import os
sys.path.append(os.path.expandvars('$SDE/install/lib/python2.7/site-packages/tofino/'))
import logging
import time
import grpc
import bfrt_grpc.bfruntime_pb2 as bfruntime_pb2
import bfrt_grpc.client as client
import random
from pkts import *
import collections
import math


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
INVALID_VALUE_8bit = 0x7F
INVALID_VALUE_16bit = 0x7FFF


def register_write(target, register_object, register_name, index, register_value):
        print("Inserting entry in %s register with value = %s ", str(register_name), str(register_value))

        register_object.entry_add(
            target,
            [register_object.make_key([client.KeyTuple('$REGISTER_INDEX', index)])],
            [register_object.make_data([client.DataTuple(register_name, register_value)])])

def test_register_read(target, register_object, register_name, pipe_id, index):    
    resp = register_object.entry_get(
            target,
            [register_object.make_key([client.KeyTuple('$REGISTER_INDEX', index)])],
            {"from_hw": True})
    # TODO: Modify 0 for other pipe IDs currenlty showing only pipe 0 value
    
    data_dict = next(resp)[0].to_dict()
    res = data_dict[register_name][0]
    print("Reading Register: %s [%d] = %d", str(register_name), index, res)
    return res

class LeafController():
    def __init__(self, target, bfrt_info):
        self.target = target
        self.bfrt_info = bfrt_info
        self.tables = []
        self.init_tables()
        self.init_data()
        self.set_tables()

    def init_tables(self):
        bfrt_info = self.bfrt_info
        self.register_idle_count = bfrt_info.table_get("LeafIngress.idle_count")
        self.register_idle_list = bfrt_info.table_get("LeafIngress.idle_list")
        self.register_aggregate_queue_len = bfrt_info.table_get("LeafIngress.aggregate_queue_len_list")
        self.register_linked_sq_sched = bfrt_info.table_get("LeafIngress.linked_sq_sched")
        self.register_linked_iq_sched = bfrt_info.table_get("LeafIngress.linked_iq_sched")
        self.register_queue_len_list_1 = bfrt_info.table_get("LeafIngress.queue_len_list_1")
        self.register_queue_len_list_2 = bfrt_info.table_get("LeafIngress.queue_len_list_2")
        self.register_deferred_list_1 = bfrt_info.table_get("LeafIngress.deferred_queue_len_list_1")
        self.register_deferred_list_2 = bfrt_info.table_get("LeafIngress.deferred_queue_len_list_2")
        self.register_spine_probed_id = bfrt_info.table_get("LeafIngress.spine_probed_id")
        self.register_spine_iq_len_1 = bfrt_info.table_get("LeafIngress.spine_iq_len_1")

        # MA Tables
        self.forward_falcon_switch_dst = bfrt_info.table_get("LeafIngress.forward_falcon_switch_dst")
        self.forward_falcon_switch_dst.info.key_field_annotation_add("hdr.falcon.dst_id", "wid")
        self.set_queue_len_unit = bfrt_info.table_get("LeafIngress.set_queue_len_unit")
        self.set_queue_len_unit.info.key_field_annotation_add("hdr.falcon.cluster_id", "vcid")
        self.get_cluster_num_valid = bfrt_info.table_get("LeafIngress.get_cluster_num_valid")
        self.get_cluster_num_valid.info.key_field_annotation_add("hdr.falcon.cluster_id", "vcid")
        self.adjust_random_range_ds = bfrt_info.table_get("LeafIngress.adjust_random_range_ds")
        self.adjust_random_range_ds.info.key_field_annotation_add("falcon_md.cluster_num_valid_ds", "num_valid_ds")
        self.adjust_random_range_us = bfrt_info.table_get("LeafIngress.adjust_random_range_us")
        self.adjust_random_range_us.info.key_field_annotation_add("falcon_md.cluster_num_valid_us", "num_valid_us")
        self.get_spine_dst_id = bfrt_info.table_get("LeafIngress.get_spine_dst_id")
        self.get_spine_dst_id.info.key_field_annotation_add("falcon_md.random_id_1", "random_id")

        # HW config tables (Mirror and multicast)
        self.mirror_cfg_table = bfrt_info.table_get("$mirror.cfg")

        # Add tables to list for easier cleanup()
        self.tables.append(self.register_idle_count)
        self.tables.append(self.register_idle_list)
        self.tables.append(self.register_aggregate_queue_len)
        self.tables.append(self.register_linked_sq_sched)
        self.tables.append(self.register_linked_iq_sched)
        self.tables.append(self.register_queue_len_list_1)
        self.tables.append(self.register_queue_len_list_2)
        self.tables.append(self.register_deferred_list_1)
        self.tables.append(self.register_deferred_list_2)
        self.tables.append(self.register_spine_probed_id)
        self.tables.append(self.register_spine_iq_len_1)

        self.tables.append(self.adjust_random_range_ds)
        self.tables.append(self.adjust_random_range_us)
        self.tables.append(self.forward_falcon_switch_dst)
        self.tables.append(self.set_queue_len_unit)
        self.tables.append(self.get_cluster_num_valid)
        self.tables.append(self.get_spine_dst_id)

    def init_data(self):
        self.pipe_id = 0
        self.TEST_VCLUSTER_ID = 0
        self.MAX_VCLUSTER_WORKERS = 1000 # This number should be the same in p4 code (fixed at compile time)
        self.initial_idle_count = 4
        self.initial_idle_list = [0, 1, 2, 3]
        self.intitial_qlen_state = [0, 0, 0, 0]
        self.wid_port_mapping = {0:148, 1:148, 2:148, 3:148, 7:132}
        self.port_mac_mapping = {132: 'F8:F2:1E:3A:13:EC', 148: 'F8:F2:1E:3A:13:C4'}

        self.initial_agg_qlen = 0
        self.qlen_unit = 0b00000010 # assuming 3bit showing fraction and 5bit decimal: 0.25 (4 workers in this rack)
        self.initial_linked_iq_spine = 10 # ID of linked spine for Idle link
        self.initial_linked_sq_spine = 0x7FFF # ID of linked spine for SQ link (Invalid = 0xFFFF, since we are in idle state)
        

        self.intitial_deferred_state = [0, 0, 0, 0, 0]
        self.num_valid_ds_elements = 4 # num available workers for this vcluster in this rack (the worker number will be 2^W)
        self.num_valid_us_elements = 1

        self.workers_start_idx = self.TEST_VCLUSTER_ID * self.MAX_VCLUSTER_WORKERS

    def set_tables(self):
        register_write(self.target,
                self.register_linked_iq_sched,
                register_name='LeafIngress.linked_iq_sched.f1',
                index=self.TEST_VCLUSTER_ID,
                register_value=self.initial_linked_iq_spine)

        register_write(self.target,
                self.register_linked_iq_sched,
                register_name='LeafIngress.linked_iq_sched.f1',
                index=self.TEST_VCLUSTER_ID,
                register_value=self.initial_linked_iq_spine)

        register_write(self.target,
                self.register_linked_sq_sched,
                register_name='LeafIngress.linked_sq_sched.f1',
                index=self.TEST_VCLUSTER_ID,
                register_value=self.initial_linked_sq_spine)

        register_write(self.target,
            self.register_idle_count,
            register_name='LeafIngress.idle_count.f1',
            index=self.TEST_VCLUSTER_ID,
            register_value=self.initial_idle_count)
        
        register_write(self.target,
                self.register_aggregate_queue_len,
                register_name='LeafIngress.aggregate_queue_len_list.f1',
                index=self.TEST_VCLUSTER_ID,
                register_value=self.initial_agg_qlen)

        test_register_read(self.target,
            self.register_idle_count,
            'LeafIngress.idle_count.f1',
            self.pipe_id,
            self.TEST_VCLUSTER_ID)

        # Insert idle_list values (wid of idle workers)
        for i in range(self.initial_idle_count):
            register_write(self.target,
                self.register_idle_list,
                register_name='LeafIngress.idle_list.f1',
                index=i,
                register_value=self.initial_idle_list[i])

        for i, qlen in enumerate(self.intitial_qlen_state):
            register_write(self.target,
                    self.register_queue_len_list_1,
                    register_name='LeafIngress.queue_len_list_1.f1',
                    index=self.workers_start_idx + i,
                    register_value=qlen)
            register_write(self.target,
                    self.register_queue_len_list_2,
                    register_name='LeafIngress.queue_len_list_2.f1',
                    index=self.workers_start_idx + i,
                    register_value=qlen)
            register_write(self.target,
                    self.register_deferred_list_1,
                    register_name='LeafIngress.deferred_queue_len_list_1.f1',
                    index=self.workers_start_idx + i,
                    register_value=self.intitial_deferred_state[i])

        print("********* Populating Table Entires *********")
        for wid in self.wid_port_mapping.keys():
            self.forward_falcon_switch_dst.entry_add(
                self.target,
                [self.forward_falcon_switch_dst.make_key([client.KeyTuple('hdr.falcon.dst_id', wid)])],
                [self.forward_falcon_switch_dst.make_data([client.DataTuple('port', self.wid_port_mapping[wid]), client.DataTuple('dst_mac', client.mac_to_bytes(self.port_mac_mapping[self.wid_port_mapping[wid]]))],
                                             'LeafIngress.act_forward_falcon')]
            )
        self.adjust_random_range_ds.entry_add(
                self.target,
                [self.adjust_random_range_ds.make_key([client.KeyTuple('falcon_md.cluster_num_valid_ds', 2)])],
                [self.adjust_random_range_ds.make_data([], 'LeafIngress.adjust_random_worker_range_1')]
            )
        self.adjust_random_range_ds.entry_add(
                self.target,
                [self.adjust_random_range_ds.make_key([client.KeyTuple('falcon_md.cluster_num_valid_ds', 4)])],
                [self.adjust_random_range_ds.make_data([], 'LeafIngress.adjust_random_worker_range_2')]
            )
        self.adjust_random_range_ds.entry_add(
                self.target,
                [self.adjust_random_range_ds.make_key([client.KeyTuple('falcon_md.cluster_num_valid_ds', 16)])],
                [self.adjust_random_range_ds.make_data([], 'LeafIngress.adjust_random_worker_range_4')]
            )
        self.adjust_random_range_ds.entry_add(
                self.target,
                [self.adjust_random_range_ds.make_key([client.KeyTuple('falcon_md.cluster_num_valid_ds', 256)])],
                [self.adjust_random_range_ds.make_data([], 'LeafIngress.adjust_random_worker_range_8')]
            )
        self.get_cluster_num_valid.entry_add(
                self.target,
                [self.get_cluster_num_valid.make_key([client.KeyTuple('hdr.falcon.cluster_id', self.TEST_VCLUSTER_ID)])],
                [self.get_cluster_num_valid.make_data([client.DataTuple('num_ds_elements', self.num_valid_ds_elements), client.DataTuple('num_us_elements', self.num_valid_us_elements)],
                                             'LeafIngress.act_get_cluster_num_valid')]
            )
        print("Inserted entries in forward_falcon_switch_dst table with key-values = %s ", str(self.wid_port_mapping))

        # Insert qlen unit entries
        self.set_queue_len_unit.entry_add(
                self.target,
                [self.set_queue_len_unit.make_key([client.KeyTuple('hdr.falcon.cluster_id', self.TEST_VCLUSTER_ID)])],
                [self.set_queue_len_unit.make_data([client.DataTuple('cluster_unit', self.qlen_unit)],
                                             'LeafIngress.act_set_queue_len_unit')]
            )



if __name__ == "__main__":
    # Connect to BF Runtime Server
    interface = client.ClientInterface(grpc_addr = "localhost:50052",
                                    client_id = 0,
                                    device_id = 0)
    print("Connected to BF Runtime Server")

    # Get the information about the running program on the bfrt server.
    bfrt_info = interface.bfrt_info_get()
    print('The target runs program ', bfrt_info.p4_name_get())

    # Establish that you are working with this program
    interface.bind_pipeline_config(bfrt_info.p4_name_get())

    ####### You can now use BFRT CLIENT #######
    target = client.Target(device_id=0, pipe_id=0xffff)
    leaf_controller = LeafController(target, bfrt_info)


