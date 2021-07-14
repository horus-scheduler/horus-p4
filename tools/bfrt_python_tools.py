#
# This module defines some useful functions that should be a part of
# bfrt_python, but for now they are not.
#
# To import this module, one should do something like this:
#
# import os
# import sys
# sys.path.insert(0, os.path.join(os.environ['HOME'], 'tools'))
# from bfrt_python_tools import *
#
# To that end I've also created a script that might be helpful,
# ~/tools/bfrt_python.sh that starts bfrt_python and imports the scipt
#
from bfrtcli import *
from netaddr import EUI, IPAddress

#
# Helper Functions to deal with ports
#
def devport(pipe, port):
    return ((pipe & 3) << 7) | (port & 0x7F)
def pipeport(dp):
    return ((dp & 0x180) >> 7, (dp & 0x7F))
def mcport(pipe, port):
    return pipe * 72 + port
def devport_to_mcport(dp):
    return mcport(*pipeport(dp))


# This is a useful bfrt_python function that should potentially allow one
# to quickly clear all the logical tables (including the fixed ones) in their
# data plane program.
#
# This function  can clear all P4 tables and later other fixed objects
# (once proper BfRt support is added). As of SDE-9.2.0 the support is mixed.
# As a result the function contains some workarounds.
def clear_all(verbose=True, batching=True, clear_ports=False):
    
    table_list = bfrt.info(return_info=True, print_info=False)

    # Remove port tables from the list
    port_types = ['PORT_CFG',      'PORT_FRONT_PANEL_IDX_INFO',
                  'PORT_HDL_INFO', 'PORT_STR_INFO']
    
    if not clear_ports:
        for table in list(table_list):
            if table['type'] in port_types:
                table_list.remove(table)
                
    # The order is important. We do want to clear from the top, i.e.
    # delete objects that use other objects, e.g. table entries use
    # selector groups and selector groups use action profile members.
    # Same is true for the fixed tables. However, the list of table types
    # grows, so we will first clean the tables we know and then clear the
    # rest
    for table_types in (['MATCH_DIRECT', 'MATCH_INDIRECT_SELECTOR'],
                        ['SELECTOR'],
                        ['ACTION_PROFILE'],
                        ['PRE_MGID'],
                        ['PRE_ECMP'],
                        ['PRE_NODE'],
                        []):         # This is catch-all
        for table in list(table_list):
            if table['type'] in table_types or len(table_types) == 0:
                try:
                    if verbose:
                        print("Clearing table {:<40} ... ".
                              format(table['full_name']), end='', flush=True)
                    table['node'].clear(batch=batching)
                    table_list.remove(table)
                    if verbose:
                        print('Done')
                    use_entry_list = False
                except:
                    use_entry_list = True

                # Some tables do not support clear(). Thus we'll try to get
                # a list of entries and clear them one-by-one
                if use_entry_list:
                    try:
                        if batching:
                            bfrt.batch_begin()

                        # This line can result in an exception, since
                        # not all tables support get()
                        entry_list = table['node'].get(regex=True,
                                                       return_ents=True,
                                                       print_ents=False)

                        # Not every table supports delete() method. For those
                        # tables we'll try to push in an entry with everything
                        # being zeroed out
                        has_delete = hasattr(table['node'], 'delete')
                            
                        if entry_list != -1:
                            if has_delete:
                                for entry in entry_list:
                                    entry.remove()
                            else:
                                clear_entry = table['node'].entry()
                                for entry in entry_list:
                                    entry.data = clear_entry.data
                                    # We can still have an exception here, since
                                    # not all tables support add()/mod()
                                    entry.push()
                            if verbose:
                                print('Done')
                        else:
                            print('Empty')
                        table_list.remove(table)
                        
                    except BfRtTableError as e:
                        print('Empty')
                        table_list.remove(table)
                        
                    except Exception as e:
                        # We can have in a number of ways: no get(), no add()
                        # etc. Another reason is that the table is read-only.
                        if verbose:
                            print("Failed")
                    finally:
                        if batching:
                            bfrt.batch_end()
        bfrt.complete_operations()

#    if len(table_list):
#        print('\nFailed to clear:')
#        for table in table_list:
#            print('\t', table['full_name'])
