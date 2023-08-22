from random import randint
import scapy.all as scapy

MDC_DEFAULT_PKT_SIZE = 64

field_dict = {'pkt_type': 1,
              'pool_id': 2,
              'src_id': 2,
              'dst_id': 2,
              'q_len': 1,
              'task_id': 2}

field_cls_dict = {1: scapy.XByteField,
                  2: scapy.XShortField,
                  3: scapy.X3BytesField,
                  4: scapy.XIntField,
                  8: scapy.XLongField}

HORUS_PORT = 1234
ETHER_IPV4_TYPE = 0x0800

PKT_TYPE_NEW_TASK = 0x00
PKT_TYPE_NEW_TASK_RANDOM = 0x01
PKT_TYPE_TASK_DONE = 0x02
PKT_TYPE_TASK_DONE_IDLE = 0x03
PKT_TYPE_QUEUE_REMOVE = 0x04
PKT_TYPE_SCAN_QUEUE_SIGNAL = 0x05
PKT_TYPE_IDLE_SIGNAL = 0x06
PKT_TYPE_QUEUE_SIGNAL = 0x07
PKT_TYPE_PROBE_IDLE_QUEUE = 0x08
PKT_TYPE_PROBE_IDLE_RESPONSE = 0x09
PKT_TYPE_IDLE_REMOVE = 0x0a
PKT_TYPE_QUEUE_SIGNAL_INIT = 0x0b

def get_field(name):
    exists = type(name) == str and name.lower() in field_dict
    if exists:
        field_size = field_dict[name.lower()]
        if field_size in field_cls_dict:
            cls = field_cls_dict[field_size]
            return cls(name.lower(), 0)
        raise ValueError('field_size is incorrect')
    raise ValueError('field is not supported')

class HorusPacket(scapy.Packet):
    name = 'horusPacket'
    fields_desc = [
        get_field('pkt_type'),
        get_field('pool_id'),
        get_field('src_id'),
        get_field('dst_id'),
        get_field('q_len'),
        get_field('task_id')
    ]

def get_random_ip_addresses():
    ip_list = [('100.168.1.1', '100.132.44.1'),
               ('72.67.48.53', '72.10.30.55'),
               ]
    rand_idx = randint(0, len(ip_list)-1)
    return ip_list[rand_idx]

def generate_load(length):
    load = ''
    for i in range(length):
        load += chr(randint(0, 255))
    return load

def make_eth_hdr(src_mac=None, dst_mac=None, ip_encap=False, **kwargs):
    hdr = scapy.Ether()
    hdr.type = ETHER_IPV4_TYPE
    if src_mac:
        hdr.src = src_mac
    if dst_mac:
        hdr.dst = dst_mac
    return hdr

def make_horus_task_pkt(dst_ip, pool_id,  src_id, dst_id, q_len=0, task_id=1000, pkt_len=128, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_NEW_TASK, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=q_len, task_id=task_id)

    data_len = pkt_len - len(eth_hdr) - len(horus_hdr)
    if data_len < 0:
        data_len = 0
    payload = generate_load(data_len)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(sport=HORUS_PORT, dport=HORUS_PORT, chksum=0) / horus_hdr / payload
    return pkt

def make_horus_probe_idle_pkt(dst_ip, pool_id, src_id, dst_id, task_id, q_len=0, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_PROBE_IDLE_QUEUE, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=q_len, task_id=task_id)

    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    
    return pkt

def make_horus_probe_idle_response_pkt(dst_ip, pool_id, src_id, dst_id, task_id, q_len, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_PROBE_IDLE_RESPONSE, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=q_len, task_id=task_id)

    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    
    return pkt

def make_horus_scan_queue_pkt(dst_ip, pool_id, src_id, dst_id, task_id, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_SCAN_QUEUE_SIGNAL, pool_id=pool_id,  src_id=src_id, dst_id=dst_id, q_len=0, task_id=task_id)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    return pkt

def make_horus_queue_remove_pkt(dst_ip, pool_id, src_id, dst_id, task_id, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_QUEUE_REMOVE, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=0, task_id=task_id)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    return pkt

def make_horus_idle_signal_pkt(dst_ip, pool_id, src_id, dst_id, task_id, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_IDLE_SIGNAL, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=0, task_id=task_id)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    return pkt

def make_horus_idle_remove_pkt(dst_ip, pool_id, src_id, dst_id, task_id, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    horus_hdr = HorusPacket(pkt_type=PKT_TYPE_IDLE_REMOVE, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=0, task_id=task_id)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    return pkt

def make_horus_queue_signal_pkt(dst_ip, pool_id, src_id, dst_id, task_id, is_init, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    if is_init:
        pkt_type = PKT_TYPE_QUEUE_SIGNAL_INIT
    else:
        pkt_type = PKT_TYPE_QUEUE_SIGNAL
    horus_hdr = HorusPacket(pkt_type=pkt_type, pool_id=pool_id,  src_id=src_id, dst_id=dst_id, q_len=0, task_id=task_id)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    return pkt


def make_horus_task_done_pkt(dst_ip, pool_id,  src_id, dst_id, is_idle, q_len, task_id=1000, pkt_len=128, **kwargs):
    eth_hdr = make_eth_hdr(**kwargs)
    if is_idle:
        horus_hdr = HorusPacket(pkt_type=PKT_TYPE_TASK_DONE_IDLE, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=q_len, task_id=task_id)
    else:
        horus_hdr = HorusPacket(pkt_type=PKT_TYPE_TASK_DONE, pool_id=pool_id, src_id=src_id, dst_id=dst_id, q_len=q_len, task_id=task_id)
    pkt = eth_hdr / scapy.IP(src='192.168.0.16', dst=dst_ip) / scapy.UDP(dport=HORUS_PORT, chksum=0) / horus_hdr
    return pkt




