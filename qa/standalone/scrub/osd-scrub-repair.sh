#!/usr/bin/env bash
#
# Copyright (C) 2014 Red Hat <contact@redhat.com>
#
# Author: Loic Dachary <loic@dachary.org>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU Library Public License as published by
# the Free Software Foundation; either version 2, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library Public License for more details.
#
set -x
source $CEPH_ROOT/qa/standalone/ceph-helpers.sh

if [ `uname` = FreeBSD ]; then
    # erasure coding overwrites are only tested on Bluestore
    # erasure coding on filestore is unsafe
    # http://docs.ceph.com/docs/master/rados/operations/erasure-code/#erasure-coding-with-overwrites
    use_ec_overwrite=false
else
    use_ec_overwrite=true
fi

# Test development and debugging
# Set to "yes" in order to ignore diff errors and save results to update test
getjson="no"

# Ignore the epoch and filter out the attr '_' value because it has date information and won't match
if [ "$(jq --version 2>&1 | awk '{ print $3}')" = "1.3" ]; then # Not sure all versions that apply here
    jqfilter='.inconsistents | (.[].shards[].attrs[] | select(.name == "_") | .value) |= "----Stripped-by-test----"'
else
    jqfilter='.inconsistents | (.[].shards[].attrs[]? | select(.name == "_") | .value) |= "----Stripped-by-test----"'
fi
sortkeys='import json; import sys ; JSON=sys.stdin.read() ; ud = json.loads(JSON) ; print json.dumps(ud, sort_keys=True, indent=2)'

# Remove items are not consistent across runs, the pg interval and client
sedfilter='s/\([ ]*\"\(selected_\)*object_info\":.*head[(]\)[^[:space:]]* [^[:space:]]* \(.*\)/\1\3/'

function run() {
    local dir=$1
    shift

    export CEPH_MON="127.0.0.1:7107" # git grep '\<7107\>' : there must be only one
    export CEPH_ARGS
    CEPH_ARGS+="--fsid=$(uuidgen) --auth-supported=none "
    CEPH_ARGS+="--mon-host=$CEPH_MON "
    CEPH_ARGS+="--osd-skip-data-digest=false "

    local funcs=${@:-$(set | sed -n -e 's/^\(TEST_[0-9a-z_]*\) .*/\1/p')}
    for func in $funcs ; do
        $func $dir || return 1
    done
}

function add_something() {
    local dir=$1
    local poolname=$2
    local obj=${3:-SOMETHING}
    local scrub=${4:-noscrub}

    if [ "$scrub" = "noscrub" ];
    then
        ceph osd set noscrub || return 1
        ceph osd set nodeep-scrub || return 1
    else
        ceph osd unset noscrub || return 1
        ceph osd unset nodeep-scrub || return 1
    fi

    local payload=ABCDEF
    echo $payload > $dir/ORIGINAL
    rados --pool $poolname put $obj $dir/ORIGINAL || return 1
}

#
# Corrupt one copy of a replicated pool
#
function TEST_corrupt_and_repair_replicated() {
    local dir=$1
    local poolname=rbd

    setup $dir || return 1
    run_mon $dir a --osd_pool_default_size=2 || return 1
    run_mgr $dir x || return 1
    run_osd $dir 0 || return 1
    run_osd $dir 1 || return 1
    create_rbd_pool || return 1
    wait_for_clean || return 1

    add_something $dir $poolname || return 1
    corrupt_and_repair_one $dir $poolname $(get_not_primary $poolname SOMETHING) || return 1
    # Reproduces http://tracker.ceph.com/issues/8914
    corrupt_and_repair_one $dir $poolname $(get_primary $poolname SOMETHING) || return 1

    teardown $dir || return 1
}

function corrupt_and_repair_two() {
    local dir=$1
    local poolname=$2
    local first=$3
    local second=$4

    #
    # 1) remove the corresponding file from the OSDs
    #
    pids=""
    run_in_background pids objectstore_tool $dir $first SOMETHING remove
    run_in_background pids objectstore_tool $dir $second SOMETHING remove
    wait_background pids
    return_code=$?
    if [ $return_code -ne 0 ]; then return $return_code; fi

    #
    # 2) repair the PG
    #
    local pg=$(get_pg $poolname SOMETHING)
    repair $pg
    #
    # 3) The files must be back
    #
    pids=""
    run_in_background pids objectstore_tool $dir $first SOMETHING list-attrs
    run_in_background pids objectstore_tool $dir $second SOMETHING list-attrs
    wait_background pids
    return_code=$?
    if [ $return_code -ne 0 ]; then return $return_code; fi

    rados --pool $poolname get SOMETHING $dir/COPY || return 1
    diff $dir/ORIGINAL $dir/COPY || return 1
}

#
# 1) add an object
# 2) remove the corresponding file from a designated OSD
# 3) repair the PG
# 4) check that the file has been restored in the designated OSD
#
function corrupt_and_repair_one() {
    local dir=$1
    local poolname=$2
    local osd=$3

    #
    # 1) remove the corresponding file from the OSD
    #
    objectstore_tool $dir $osd SOMETHING remove || return 1
    #
    # 2) repair the PG
    #
    local pg=$(get_pg $poolname SOMETHING)
    repair $pg
    #
    # 3) The file must be back
    #
    objectstore_tool $dir $osd SOMETHING list-attrs || return 1
    rados --pool $poolname get SOMETHING $dir/COPY || return 1
    diff $dir/ORIGINAL $dir/COPY || return 1
}

function corrupt_and_repair_erasure_coded() {
    local dir=$1
    local poolname=$2

    add_something $dir $poolname || return 1

    local primary=$(get_primary $poolname SOMETHING)
    local -a osds=($(get_osds $poolname SOMETHING | sed -e "s/$primary//"))
    local not_primary_first=${osds[0]}
    local not_primary_second=${osds[1]}

    # Reproduces http://tracker.ceph.com/issues/10017
    corrupt_and_repair_one $dir $poolname $primary  || return 1
    # Reproduces http://tracker.ceph.com/issues/10409
    corrupt_and_repair_one $dir $poolname $not_primary_first || return 1
    corrupt_and_repair_two $dir $poolname $not_primary_first $not_primary_second || return 1
    corrupt_and_repair_two $dir $poolname $primary $not_primary_first || return 1

}

function create_ec_pool() {
    local pool_name=$1
    local allow_overwrites=$2

    ceph osd erasure-code-profile set myprofile crush-failure-domain=osd $3 $4 $5 $6 $7 || return 1

    create_pool "$poolname" 1 1 erasure myprofile || return 1

    if [ "$allow_overwrites" = "true" ]; then
        ceph osd pool set "$poolname" allow_ec_overwrites true || return 1
    fi

    wait_for_clean || return 1
    return 0
}

function auto_repair_erasure_coded() {
    local dir=$1
    local allow_overwrites=$2
    local poolname=ecpool

    # Launch a cluster with 5 seconds scrub interval
    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    local ceph_osd_args="--osd-scrub-auto-repair=true \
            --osd-deep-scrub-interval=5 \
            --osd-scrub-max-interval=5 \
            --osd-scrub-min-interval=5 \
            --osd-scrub-interval-randomize-ratio=0"
    for id in $(seq 0 2) ; do
	if [ "$allow_overwrites" = "true" ]; then
            run_osd_bluestore $dir $id $ceph_osd_args || return 1
	else
            run_osd $dir $id $ceph_osd_args || return 1
	fi
    done
    create_rbd_pool || return 1
    wait_for_clean || return 1

    # Create an EC pool
    create_ec_pool $poolname $allow_overwrites k=2 m=1 || return 1

    # Put an object
    local payload=ABCDEF
    echo $payload > $dir/ORIGINAL
    rados --pool $poolname put SOMETHING $dir/ORIGINAL || return 1

    # Remove the object from one shard physically
    # Restarted osd get $ceph_osd_args passed
    objectstore_tool $dir $(get_not_primary $poolname SOMETHING) SOMETHING remove || return 1
    # Wait for auto repair
    local pgid=$(get_pg $poolname SOMETHING)
    wait_for_scrub $pgid "$(get_last_scrub_stamp $pgid)"
    wait_for_clean || return 1
    # Verify - the file should be back
    # Restarted osd get $ceph_osd_args passed
    objectstore_tool $dir $(get_not_primary $poolname SOMETHING) SOMETHING list-attrs || return 1
    rados --pool $poolname get SOMETHING $dir/COPY || return 1
    diff $dir/ORIGINAL $dir/COPY || return 1

    # Tear down
    teardown $dir || return 1
}

function TEST_auto_repair_erasure_coded_appends() {
    auto_repair_erasure_coded $1 false
}

function TEST_auto_repair_erasure_coded_overwrites() {
    if [ "$use_ec_overwrite" = "true" ]; then
        auto_repair_erasure_coded $1 true
    fi
}

function corrupt_and_repair_jerasure() {
    local dir=$1
    local allow_overwrites=$2
    local poolname=ecpool

    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    for id in $(seq 0 3) ; do
	if [ "$allow_overwrites" = "true" ]; then
            run_osd_bluestore $dir $id || return 1
	else
            run_osd $dir $id || return 1
	fi
    done
    create_rbd_pool || return 1
    wait_for_clean || return 1

    create_ec_pool $poolname $allow_overwrites k=2 m=2 || return 1
    corrupt_and_repair_erasure_coded $dir $poolname || return 1

    teardown $dir || return 1
}

function TEST_corrupt_and_repair_jerasure_appends() {
    corrupt_and_repair_jerasure $1
}

function TEST_corrupt_and_repair_jerasure_overwrites() {
    if [ "$use_ec_overwrite" = "true" ]; then
        corrupt_and_repair_jerasure $1 true
    fi
}

function corrupt_and_repair_lrc() {
    local dir=$1
    local allow_overwrites=$2
    local poolname=ecpool

    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    for id in $(seq 0 9) ; do
	if [ "$allow_overwrites" = "true" ]; then
            run_osd_bluestore $dir $id || return 1
	else
            run_osd $dir $id || return 1
	fi
    done
    create_rbd_pool || return 1
    wait_for_clean || return 1

    create_ec_pool $poolname $allow_overwrites k=4 m=2 l=3 plugin=lrc || return 1
    corrupt_and_repair_erasure_coded $dir $poolname || return 1

    teardown $dir || return 1
}

function TEST_corrupt_and_repair_lrc_appends() {
    corrupt_and_repair_jerasure $1
}

function TEST_corrupt_and_repair_lrc_overwrites() {
    if [ "$use_ec_overwrite" = "true" ]; then
        corrupt_and_repair_jerasure $1 true
    fi
}

function unfound_erasure_coded() {
    local dir=$1
    local allow_overwrites=$2
    local poolname=ecpool
    local payload=ABCDEF

    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    for id in $(seq 0 3) ; do
	if [ "$allow_overwrites" = "true" ]; then
            run_osd_bluestore $dir $id || return 1
	else
            run_osd $dir $id || return 1
	fi
    done
    create_rbd_pool || return 1
    wait_for_clean || return 1

    create_ec_pool $poolname $allow_overwrites k=2 m=2 || return 1

    add_something $dir $poolname || return 1

    local primary=$(get_primary $poolname SOMETHING)
    local -a osds=($(get_osds $poolname SOMETHING | sed -e "s/$primary//"))
    local not_primary_first=${osds[0]}
    local not_primary_second=${osds[1]}
    local not_primary_third=${osds[2]}

    #
    # 1) remove the corresponding file from the OSDs
    #
    pids=""
    run_in_background pids objectstore_tool $dir $not_primary_first SOMETHING remove
    run_in_background pids objectstore_tool $dir $not_primary_second SOMETHING remove
    run_in_background pids objectstore_tool $dir $not_primary_third SOMETHING remove
    wait_background pids
    return_code=$?
    if [ $return_code -ne 0 ]; then return $return_code; fi

    #
    # 2) repair the PG
    #
    local pg=$(get_pg $poolname SOMETHING)
    repair $pg
    #
    # 3) check pg state
    #
    # it may take a bit to appear due to mon/mgr asynchrony
    for f in `seq 1 60`; do
	ceph -s | grep "1/1 objects unfound" && break
	sleep 1
    done
    ceph -s|grep "4 osds: 4 up, 4 in" || return 1
    ceph -s|grep "1/1 objects unfound" || return 1

    teardown $dir || return 1
}

function TEST_unfound_erasure_coded_appends() {
    unfound_erasure_coded $1
}

function TEST_unfound_erasure_coded_overwrites() {
    if [ "$use_ec_overwrite" = "true" ]; then
        unfound_erasure_coded $1 true
    fi
}

#
# list_missing for EC pool
#
function list_missing_erasure_coded() {
    local dir=$1
    local allow_overwrites=$2
    local poolname=ecpool

    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    for id in $(seq 0 2) ; do
	if [ "$allow_overwrites" = "true" ]; then
            run_osd_bluestore $dir $id || return 1
	else
            run_osd $dir $id || return 1
	fi
    done
    create_rbd_pool || return 1
    wait_for_clean || return 1

    create_ec_pool $poolname $allow_overwrites k=2 m=1 || return 1

    # Put an object and remove the two shards (including primary)
    add_something $dir $poolname MOBJ0 || return 1
    local -a osds0=($(get_osds $poolname MOBJ0))

    # Put another object and remove two shards (excluding primary)
    add_something $dir $poolname MOBJ1 || return 1
    local -a osds1=($(get_osds $poolname MOBJ1))

    # Stop all osd daemons
    for id in $(seq 0 2) ; do
        kill_daemons $dir TERM osd.$id >&2 < /dev/null || return 1
    done

    id=${osds0[0]}
    ceph-objectstore-tool --data-path $dir/$id \
        MOBJ0 remove || return 1
    id=${osds0[1]}
    ceph-objectstore-tool --data-path $dir/$id \
        MOBJ0 remove || return 1

    id=${osds1[1]}
    ceph-objectstore-tool --data-path $dir/$id \
        MOBJ1 remove || return 1
    id=${osds1[2]}
    ceph-objectstore-tool --data-path $dir/$id \
        MOBJ1 remove || return 1

    for id in $(seq 0 2) ; do
        activate_osd $dir $id >&2 || return 1
    done
    create_rbd_pool || return 1
    wait_for_clean || return 1

    # Get get - both objects should in the same PG
    local pg=$(get_pg $poolname MOBJ0)

    # Repair the PG, which triggers the recovering,
    # and should mark the object as unfound
    repair $pg

    for i in $(seq 0 120) ; do
        [ $i -lt 60 ] || return 1
        matches=$(ceph pg $pg list_missing | egrep "MOBJ0|MOBJ1" | wc -l)
        [ $matches -eq 2 ] && break
    done

    teardown $dir || return 1
}

function TEST_list_missing_erasure_coded_appends() {
    list_missing_erasure_coded $1 false
}

function TEST_list_missing_erasure_coded_overwrites() {
    if [ "$use_ec_overwrite" = "true" ]; then
        list_missing_erasure_coded $1 true
    fi
}

#
# Corrupt one copy of a replicated pool
#
function TEST_corrupt_scrub_replicated() {
    local dir=$1
    local poolname=csr_pool
    local total_objs=16

    setup $dir || return 1
    run_mon $dir a --osd_pool_default_size=2 || return 1
    run_mgr $dir x || return 1
    run_osd $dir 0 || return 1
    run_osd $dir 1 || return 1
    create_rbd_pool || return 1
    wait_for_clean || return 1

    create_pool foo 1 || return 1
    create_pool $poolname 1 1 || return 1
    wait_for_clean || return 1

    for i in $(seq 1 $total_objs) ; do
        objname=ROBJ${i}
        add_something $dir $poolname $objname || return 1

        rados --pool $poolname setomapheader $objname hdr-$objname || return 1
        rados --pool $poolname setomapval $objname key-$objname val-$objname || return 1
    done

    local pg=$(get_pg $poolname ROBJ0)

    # Compute an old omap digest and save oi
    CEPH_ARGS='' ceph daemon $(get_asok_path osd.0) \
        config set osd_deep_scrub_update_digest_min_age 0
    CEPH_ARGS='' ceph daemon $(get_asok_path osd.1) \
        config set osd_deep_scrub_update_digest_min_age 0
    pg_deep_scrub $pg

    for i in $(seq 1 $total_objs) ; do
        objname=ROBJ${i}

        # Alternate corruption between osd.0 and osd.1
        local osd=$(expr $i % 2)

        case $i in
        1)
            # Size (deep scrub data_digest too)
            local payload=UVWXYZZZ
            echo $payload > $dir/CORRUPT
            objectstore_tool $dir $osd $objname set-bytes $dir/CORRUPT || return 1
            ;;

        2)
            # digest (deep scrub only)
            local payload=UVWXYZ
            echo $payload > $dir/CORRUPT
            objectstore_tool $dir $osd $objname set-bytes $dir/CORRUPT || return 1
            ;;

        3)
             # missing
             objectstore_tool $dir $osd $objname remove || return 1
             ;;

         4)
             # Modify omap value (deep scrub only)
             objectstore_tool $dir $osd $objname set-omap key-$objname $dir/CORRUPT || return 1
             ;;

         5)
            # Delete omap key (deep scrub only)
            objectstore_tool $dir $osd $objname rm-omap key-$objname || return 1
            ;;

         6)
            # Add extra omap key (deep scrub only)
            echo extra > $dir/extra-val
            objectstore_tool $dir $osd $objname set-omap key2-$objname $dir/extra-val || return 1
            rm $dir/extra-val
            ;;

         7)
            # Modify omap header (deep scrub only)
            echo -n newheader > $dir/hdr
            objectstore_tool $dir $osd $objname set-omaphdr $dir/hdr || return 1
            rm $dir/hdr
            ;;

         8)
            rados --pool $poolname setxattr $objname key1-$objname val1-$objname || return 1
            rados --pool $poolname setxattr $objname key2-$objname val2-$objname || return 1

            # Break xattrs
            echo -n bad-val > $dir/bad-val
            objectstore_tool $dir $osd $objname set-attr _key1-$objname $dir/bad-val || return 1
            objectstore_tool $dir $osd $objname rm-attr _key2-$objname || return 1
            echo -n val3-$objname > $dir/newval
            objectstore_tool $dir $osd $objname set-attr _key3-$objname $dir/newval || return 1
            rm $dir/bad-val $dir/newval
            ;;

        9)
            objectstore_tool $dir $osd $objname get-attr _ > $dir/robj9-oi
            echo -n D > $dir/change
            rados --pool $poolname put $objname $dir/change
            objectstore_tool $dir $osd $objname set-attr _ $dir/robj9-oi
            rm $dir/oi $dir/change
            ;;

          # ROBJ10 must be handled after digests are re-computed by a deep scrub below
          # ROBJ11 must be handled with config change before deep scrub
          # ROBJ12 must be handled with config change before scrubs
          # ROBJ13 must be handled before scrubs

        14)
            echo -n bad-val > $dir/bad-val
            objectstore_tool $dir 0 $objname set-attr _ $dir/bad-val || return 1
            objectstore_tool $dir 1 $objname rm-attr _ || return 1
            rm $dir/bad-val
            ;;

        15)
            objectstore_tool $dir $osd $objname rm-attr _ || return 1
            ;;

        16)
            objectstore_tool $dir 0 $objname rm-attr snapset || return 1
            echo -n bad-val > $dir/bad-val
            objectstore_tool $dir 1 $objname set-attr snapset $dir/bad-val || return 1

        esac
    done

    local pg=$(get_pg $poolname ROBJ0)

    inject_eio rep data $poolname ROBJ11 $dir 0 || return 1 # shard 0 of [1, 0], osd.1
    inject_eio rep mdata $poolname ROBJ12 $dir 1 || return 1 # shard 1 of [1, 0], osd.0
    inject_eio rep mdata $poolname ROBJ13 $dir 1 || return 1 # shard 1 of [1, 0], osd.0
    inject_eio rep data $poolname ROBJ13 $dir 0 || return 1 # shard 0 of [1, 0], osd.1

    pg_scrub $pg

    rados list-inconsistent-pg $poolname > $dir/json || return 1
    # Check pg count
    test $(jq '. | length' $dir/json) = "1" || return 1
    # Check pgid
    test $(jq -r '.[0]' $dir/json) = $pg || return 1

    rados list-inconsistent-obj $pg > $dir/json || return 1
    # Get epoch for repair-get requests
    epoch=$(jq .epoch $dir/json)

    jq "$jqfilter" << EOF | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/checkcsjson
{
  "inconsistents": [
    {
      "shards": [
        {
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "size": 9,
          "errors": [
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:ce3f1d6a:::ROBJ1:head(47'54 osd.0.0:53 dirty|omap|data_digest s 7 uv 3 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 3,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ1"
      }
    },
    {
      "shards": [
        {
          "errors": [
            "stat_error"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:bc819597:::ROBJ12:head(47'52 osd.0.0:51 dirty|omap|data_digest s 7 uv 36 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "stat_error"
      ],
      "errors": [],
      "object": {
        "version": 36,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ12"
      }
    },
    {
      "shards": [
        {
          "errors": [
            "stat_error"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:d60617f9:::ROBJ13:head(47'55 osd.0.0:54 dirty|omap|data_digest s 7 uv 39 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "stat_error"
      ],
      "errors": [],
      "object": {
        "version": 39,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ13"
      }
    },
    {
      "shards": [
        {
          "size": 7,
          "attrs": [
            {
              "Base64": false,
              "value": "",
              "name": "_"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "errors": [
            "oi_attr_corrupted"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "size": 7,
          "attrs": [
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "errors": [
            "oi_attr_missing"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "union_shard_errors": [
        "oi_attr_missing",
        "oi_attr_corrupted"
      ],
      "errors": [],
      "object": {
        "version": 0,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ14"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "size": 7,
          "errors": [
            "oi_attr_missing"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:30259878:::ROBJ15:head(47'46 osd.0.0:45 dirty|omap|data_digest s 7 uv 45 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "oi_attr_missing"
      ],
      "errors": [],
      "object": {
        "version": 45,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ15"
      }
    },
    {
      "errors": [],
      "object": {
      "locator": "",
      "name": "ROBJ16",
      "nspace": "",
      "snap": "head",
      "version": 0
       },
        "shards": [
      {
        "attrs": [
          {
            "Base64": true,
            "name": "_",
            "value": ""
          }
        ],
        "errors": [
          "ss_attr_missing"
        ],
        "osd": 0,
        "primary": false,
        "size": 7
      },
      {
        "attrs": [
          {
            "Base64": true,
            "name": "_",
            "value": ""
          },
          {
            "Base64": false,
            "name": "snapset",
            "value": "bad-val"
          }
        ],
        "errors": [
          "ss_attr_corrupted"
        ],
        "osd": 1,
        "primary": true,
        "size": 7
      }
      ],
      "union_shard_errors": [
        "ss_attr_missing",
        "ss_attr_corrupted"
      ]
    },
    {
      "shards": [
        {
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "errors": [
            "missing"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:f2a5b2a4:::ROBJ3:head(47'57 osd.0.0:56 dirty|omap|data_digest s 7 uv 9 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "missing"
      ],
      "errors": [],
      "object": {
        "version": 9,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ3"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "bad-val",
              "name": "_key1-ROBJ8"
            },
            {
              "Base64": false,
              "value": "val3-ROBJ8",
              "name": "_key3-ROBJ8"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-ROBJ8",
              "name": "_key1-ROBJ8"
            },
            {
              "Base64": false,
              "value": "val2-ROBJ8",
              "name": "_key2-ROBJ8"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:86586531:::ROBJ8:head(82'62 client.4351.0:1 dirty|omap|data_digest s 7 uv 66 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "attr_value_mismatch",
        "attr_name_mismatch"
      ],
      "object": {
        "version": 66,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ8"
      }
    },
    {
      "shards": [
        {
          "object_info": "3:ffdb2004:::ROBJ9:head(102'63 client.4433.0:1 dirty|omap|data_digest s 1 uv 67 dd 2b63260d alloc_hint [0 0 0])",
          "size": 1,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "object_info": "3:ffdb2004:::ROBJ9:head(47'60 osd.0.0:59 dirty|omap|data_digest s 7 uv 27 dd 2ddbf8f5 alloc_hint [0 0 0])",
          "size": 1,
          "errors": [
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:ffdb2004:::ROBJ9:head(102'63 client.4433.0:1 dirty|omap|data_digest s 1 uv 67 dd 2b63260d alloc_hint [0 0 0])",
      "union_shard_errors": [
         "obj_size_oi_mismatch"
      ],
      "errors": [
        "object_info_inconsistency"
      ],
      "object": {
        "version": 67,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ9"
      }
    }
  ],
  "epoch": 0
}
EOF

    jq "$jqfilter" $dir/json | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/csjson
    diff ${DIFFCOLOPTS} $dir/checkcsjson $dir/csjson || test $getjson = "yes" || return 1
    if test $getjson = "yes"
    then
        jq '.' $dir/json > save1.json
    fi

    if which jsonschema > /dev/null;
    then
      jsonschema -i $dir/json $CEPH_ROOT/doc/rados/command/list-inconsistent-obj.json || return 1
    fi

    objname=ROBJ9
    # Change data and size again because digest was recomputed
    echo -n ZZZ > $dir/change
    rados --pool $poolname put $objname $dir/change
    # Set one to an even older value
    objectstore_tool $dir 0 $objname set-attr _ $dir/robj9-oi
    rm $dir/oi $dir/change

    objname=ROBJ10
    objectstore_tool $dir 1 $objname get-attr _ > $dir/oi
    rados --pool $poolname setomapval $objname key2-$objname val2-$objname
    objectstore_tool $dir 0 $objname set-attr _ $dir/oi
    objectstore_tool $dir 1 $objname set-attr _ $dir/oi
    rm $dir/oi

    inject_eio rep data $poolname ROBJ11 $dir 0 || return 1 # shard 0 of [1, 0], osd.1
    inject_eio rep mdata $poolname ROBJ12 $dir 1 || return 1 # shard 1 of [1, 0], osd.0
    inject_eio rep mdata $poolname ROBJ13 $dir 1 || return 1 # shard 1 of [1, 0], osd.0
    inject_eio rep data $poolname ROBJ13 $dir 0 || return 1 # shard 0 of [1, 0], osd.1
    pg_deep_scrub $pg

    rados list-inconsistent-pg $poolname > $dir/json || return 1
    # Check pg count
    test $(jq '. | length' $dir/json) = "1" || return 1
    # Check pgid
    test $(jq -r '.[0]' $dir/json) = $pg || return 1

    rados list-inconsistent-obj $pg > $dir/json || return 1
    # Get epoch for repair-get requests
    epoch=$(jq .epoch $dir/json)

    jq "$jqfilter" << EOF | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/checkcsjson
{
  "inconsistents": [
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xf5fba2c6",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2d4a11c2",
          "omap_digest": "0xf5fba2c6",
          "size": 9,
          "errors": [
            "data_digest_mismatch_oi",
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:ce3f1d6a:::ROBJ1:head(47'54 osd.0.0:53 dirty|omap|data_digest s 7 uv 3 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "data_digest_mismatch_oi",
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "data_digest_mismatch",
        "size_mismatch"
      ],
      "object": {
        "version": 3,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ1"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xa03cef03",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "size": 7,
          "errors": [
            "read_error"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:87abbf36:::ROBJ11:head(47'48 osd.0.0:47 dirty|omap|data_digest s 7 uv 33 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "read_error"
      ],
      "errors": [],
      "object": {
        "version": 33,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ11"
      }
    },
    {
      "shards": [
        {
          "errors": [
            "stat_error"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x067f306a",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:bc819597:::ROBJ12:head(47'52 osd.0.0:51 dirty|omap|data_digest s 7 uv 36 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "stat_error"
      ],
      "errors": [],
      "object": {
        "version": 36,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ12"
      }
    },
    {
      "shards": [
        {
          "errors": [
            "stat_error"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "size": 7,
          "errors": [
            "read_error"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "union_shard_errors": [
        "stat_error",
        "read_error"
      ],
      "errors": [],
      "object": {
        "version": 0,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ13"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": false,
              "value": "",
              "name": "_"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x4f14f849",
          "size": 7,
          "errors": [
            "oi_attr_corrupted"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x4f14f849",
          "size": 7,
          "errors": [
            "oi_attr_missing"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "union_shard_errors": [
        "oi_attr_missing",
        "oi_attr_corrupted"
      ],
      "errors": [],
      "object": {
        "version": 0,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ14"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x2d2a4d6e",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x2d2a4d6e",
          "size": 7,
          "errors": [
            "oi_attr_missing"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:30259878:::ROBJ15:head(47'46 osd.0.0:45 dirty|omap|data_digest s 7 uv 45 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "oi_attr_missing"
      ],
      "errors": [],
      "object": {
        "version": 45,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ15"
      }
    },
    {
      "errors": [],
      "object": {
      "locator": "",
      "name": "ROBJ16",
      "nspace": "",
      "snap": "head",
      "version": 0
       },
        "shards": [
      {
        "attrs": [
          {
            "Base64": true,
            "name": "_",
            "value": ""
          }
        ],
        "data_digest": "0x2ddbf8f5",
        "errors": [
          "ss_attr_missing"
        ],
        "omap_digest": "0x8b699207",
        "osd": 0,
        "primary": false,
        "size": 7
      },
      {
        "attrs": [
          {
            "Base64": true,
            "name": "_",
            "value": ""
          },
          {
            "Base64": false,
            "name": "snapset",
            "value": "bad-val"
          }
        ],
        "data_digest": "0x2ddbf8f5",
        "errors": [
          "ss_attr_corrupted"
        ],
        "omap_digest": "0x8b699207",
        "osd": 1,
        "primary": true,
        "size": 7
      }
      ],
      "union_shard_errors": [
        "ss_attr_missing",
        "ss_attr_corrupted"
      ]
    },
    {
      "shards": [
        {
          "data_digest": "0x578a4830",
          "omap_digest": "0xf8e11918",
          "size": 7,
          "errors": [
            "data_digest_mismatch_oi"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xf8e11918",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:e97ce31e:::ROBJ2:head(47'56 osd.0.0:55 dirty|omap|data_digest s 7 uv 6 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "data_digest_mismatch_oi"
      ],
      "errors": [
        "data_digest_mismatch"
      ],
      "object": {
        "version": 6,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ2"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x00b35dfd",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "errors": [
            "missing"
          ],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:f2a5b2a4:::ROBJ3:head(47'57 osd.0.0:56 dirty|omap|data_digest s 7 uv 9 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "missing"
      ],
      "errors": [],
      "object": {
        "version": 9,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ3"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xd7178dfe",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xe2d46ea4",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:f4981d31:::ROBJ4:head(47'58 osd.0.0:57 dirty|omap|data_digest s 7 uv 12 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "omap_digest_mismatch"
      ],
      "object": {
        "version": 12,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ4"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x1a862a41",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x06cac8f6",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:f4bfd4d1:::ROBJ5:head(47'59 osd.0.0:58 dirty|omap|data_digest s 7 uv 15 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "omap_digest_mismatch"
      ],
      "object": {
        "version": 15,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ5"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x689ee887",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x179c919f",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:a53c12e8:::ROBJ6:head(47'50 osd.0.0:49 dirty|omap|data_digest s 7 uv 18 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "omap_digest_mismatch"
      ],
      "object": {
        "version": 18,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ6"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xefced57a",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0x6a73cc07",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:8b55fa4b:::ROBJ7:head(47'49 osd.0.0:48 dirty|omap|data_digest s 7 uv 21 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "omap_digest_mismatch"
      ],
      "object": {
        "version": 21,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ7"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "bad-val",
              "name": "_key1-ROBJ8"
            },
            {
              "Base64": false,
              "value": "val3-ROBJ8",
              "name": "_key3-ROBJ8"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xd6be81dc",
          "size": 7,
          "errors": [],
          "osd": 0,
          "primary": false
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-ROBJ8",
              "name": "_key1-ROBJ8"
            },
            {
              "Base64": false,
              "value": "val2-ROBJ8",
              "name": "_key2-ROBJ8"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x2ddbf8f5",
          "omap_digest": "0xd6be81dc",
          "size": 7,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:86586531:::ROBJ8:head(82'62 client.4351.0:1 dirty|omap|data_digest s 7 uv 66 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "attr_value_mismatch",
        "attr_name_mismatch"
      ],
      "object": {
        "version": 66,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ8"
      }
    },
    {
      "shards": [
        {
          "object_info": "3:ffdb2004:::ROBJ9:head(47'60 osd.0.0:59 dirty|omap|data_digest s 7 uv 27 dd 2ddbf8f5 alloc_hint [0 0 0])",
          "data_digest": "0x1f26fb26",
          "omap_digest": "0x2eecc539",
          "size": 3,
          "errors": [
            "obj_size_oi_mismatch"
          ],
          "osd": 0,
          "primary": false
        },
        {
          "object_info": "3:ffdb2004:::ROBJ9:head(122'64 client.4532.0:1 dirty|omap|data_digest s 3 uv 68 dd 1f26fb26 alloc_hint [0 0 0])",
          "data_digest": "0x1f26fb26",
          "omap_digest": "0x2eecc539",
          "size": 3,
          "errors": [],
          "osd": 1,
          "primary": true
        }
      ],
      "selected_object_info": "3:ffdb2004:::ROBJ9:head(122'64 client.4532.0:1 dirty|omap|data_digest s 3 uv 68 dd 1f26fb26 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "object_info_inconsistency"
      ],
      "object": {
        "version": 68,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "ROBJ9"
      }
    }
  ],
  "epoch": 0
}
EOF

    jq "$jqfilter" $dir/json | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/csjson
    diff ${DIFFCOLOPTS} $dir/checkcsjson $dir/csjson || test $getjson = "yes" || return 1
    if test $getjson = "yes"
    then
        jq '.' $dir/json > save2.json
    fi

    if which jsonschema > /dev/null;
    then
      jsonschema -i $dir/json $CEPH_ROOT/doc/rados/command/list-inconsistent-obj.json || return 1
    fi

    rados rmpool $poolname $poolname --yes-i-really-really-mean-it
    teardown $dir || return 1
}


#
# Test scrub errors for an erasure coded pool
#
function corrupt_scrub_erasure() {
    local dir=$1
    local allow_overwrites=$2
    local poolname=ecpool
    local total_objs=5

    setup $dir || return 1
    run_mon $dir a || return 1
    run_mgr $dir x || return 1
    for id in $(seq 0 2) ; do
	if [ "$allow_overwrites" = "true" ]; then
            run_osd_bluestore $dir $id || return 1
	else
            run_osd $dir $id || return 1
	fi
    done
    create_rbd_pool || return 1
    create_pool foo 1

    create_ec_pool $poolname $allow_overwrites k=2 m=1 stripe_unit=2K --force || return 1
    wait_for_clean || return 1

    for i in $(seq 1 $total_objs) ; do
        objname=EOBJ${i}
        add_something $dir $poolname $objname || return 1

        local osd=$(expr $i % 2)

        case $i in
        1)
            # Size (deep scrub data_digest too)
            local payload=UVWXYZZZ
            echo $payload > $dir/CORRUPT
            objectstore_tool $dir $osd $objname set-bytes $dir/CORRUPT || return 1
            ;;

        2)
            # Corrupt EC shard
            dd if=/dev/urandom of=$dir/CORRUPT bs=2048 count=1
            objectstore_tool $dir $osd $objname set-bytes $dir/CORRUPT || return 1
            ;;

        3)
             # missing
             objectstore_tool $dir $osd $objname remove || return 1
             ;;

        4)
            rados --pool $poolname setxattr $objname key1-$objname val1-$objname || return 1
            rados --pool $poolname setxattr $objname key2-$objname val2-$objname || return 1

            # Break xattrs
            echo -n bad-val > $dir/bad-val
            objectstore_tool $dir $osd $objname set-attr _key1-$objname $dir/bad-val || return 1
            objectstore_tool $dir $osd $objname rm-attr _key2-$objname || return 1
            echo -n val3-$objname > $dir/newval
            objectstore_tool $dir $osd $objname set-attr _key3-$objname $dir/newval || return 1
            rm $dir/bad-val $dir/newval
            ;;

        5)
            # Corrupt EC shard
            dd if=/dev/urandom of=$dir/CORRUPT bs=2048 count=2
            objectstore_tool $dir $osd $objname set-bytes $dir/CORRUPT || return 1
            ;;

        esac
    done

    local pg=$(get_pg $poolname EOBJ0)

    pg_scrub $pg

    rados list-inconsistent-pg $poolname > $dir/json || return 1
    # Check pg count
    test $(jq '. | length' $dir/json) = "1" || return 1
    # Check pgid
    test $(jq -r '.[0]' $dir/json) = $pg || return 1

    rados list-inconsistent-obj $pg > $dir/json || return 1
    # Get epoch for repair-get requests
    epoch=$(jq .epoch $dir/json)

    jq "$jqfilter" << EOF | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/checkcsjson
{
  "inconsistents": [
    {
      "shards": [
        {
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "size": 9,
          "shard": 0,
          "errors": [
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:9175b684:::EOBJ1:head(21'1 client.4179.0:1 dirty|data_digest s 7 uv 1 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 1,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ1"
      }
    },
    {
      "shards": [
        {
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "shard": 0,
          "errors": [
            "missing"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:b197b25d:::EOBJ3:head(37'3 client.4251.0:1 dirty|data_digest s 7 uv 3 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "missing"
      ],
      "errors": [],
      "object": {
        "version": 3,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ3"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "bad-val",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val3-EOBJ4",
              "name": "_key3-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "osd": 1,
          "primary": true,
          "shard": 0,
          "errors": [],
          "size": 2048,
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-EOBJ4",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val2-EOBJ4",
              "name": "_key2-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ]
        },
        {
          "osd": 2,
          "primary": false,
          "shard": 1,
          "errors": [],
          "size": 2048,
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-EOBJ4",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val2-EOBJ4",
              "name": "_key2-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ]
        }
      ],
      "selected_object_info": "3:5e723e06:::EOBJ4:head(45'6 client.4289.0:1 dirty|data_digest s 7 uv 6 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "attr_value_mismatch",
        "attr_name_mismatch"
      ],
      "object": {
        "version": 6,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ4"
      }
    },
    {
      "shards": [
        {
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "size": 4096,
          "shard": 0,
          "errors": [
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:8549dfb5:::EOBJ5:head(65'7 client.4441.0:1 dirty|data_digest s 7 uv 7 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 7,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ5"
      }
    }
  ],
  "epoch": 0
}
EOF

    jq "$jqfilter" $dir/json | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/csjson
    diff ${DIFFCOLOPTS} $dir/checkcsjson $dir/csjson || test $getjson = "yes" || return 1
    if test $getjson = "yes"
    then
        jq '.' $dir/json > save3.json
    fi

    if which jsonschema > /dev/null;
    then
      jsonschema -i $dir/json $CEPH_ROOT/doc/rados/command/list-inconsistent-obj.json || return 1
    fi

    pg_deep_scrub $pg

    rados list-inconsistent-pg $poolname > $dir/json || return 1
    # Check pg count
    test $(jq '. | length' $dir/json) = "1" || return 1
    # Check pgid
    test $(jq -r '.[0]' $dir/json) = $pg || return 1

    rados list-inconsistent-obj $pg > $dir/json || return 1
    # Get epoch for repair-get requests
    epoch=$(jq .epoch $dir/json)

    if [ "$allow_overwrites" = "true" ]
    then
      jq "$jqfilter" << EOF | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/checkcsjson
{
  "inconsistents": [
    {
      "shards": [
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "size": 9,
          "shard": 0,
          "errors": [
            "read_error",
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:9175b684:::EOBJ1:head(27'1 client.4155.0:1 dirty|data_digest s 7 uv 1 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "read_error",
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 1,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ1"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "shard": 0,
          "errors": [
            "missing"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:b197b25d:::EOBJ3:head(41'3 client.4199.0:1 dirty|data_digest s 7 uv 3 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "missing"
      ],
      "errors": [],
      "object": {
        "version": 3,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ3"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "bad-val",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val3-EOBJ4",
              "name": "_key3-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-EOBJ4",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val2-EOBJ4",
              "name": "_key2-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 0,
          "osd": 1,
          "primary": true
        },
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-EOBJ4",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val2-EOBJ4",
              "name": "_key2-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 1,
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:5e723e06:::EOBJ4:head(48'6 client.4223.0:1 dirty|data_digest s 7 uv 6 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "attr_value_mismatch",
        "attr_name_mismatch"
      ],
      "object": {
        "version": 6,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ4"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 4096,
          "errors": [
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "shard": 0,
          "osd": 1,
          "primary": true
        },
        {
          "data_digest": "0x00000000",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 1,
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:8549dfb5:::EOBJ5:head(65'7 client.4288.0:1 dirty|data_digest s 7 uv 7 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 7,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ5"
      }
    }
  ],
  "epoch": 0
}
EOF

    else

      jq "$jqfilter" << EOF | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/checkcsjson
{
  "inconsistents": [
    {
      "shards": [
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "size": 9,
          "shard": 0,
          "errors": [
            "read_error",
            "size_mismatch_oi",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:9175b684:::EOBJ1:head(21'1 client.4179.0:1 dirty|data_digest s 7 uv 1 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "read_error",
        "size_mismatch_oi",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 1,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ1"
      }
    },
    {
      "shards": [
        {
          "size": 2048,
          "errors": [
            "ec_hash_error"
          ],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 0,
          "osd": 1,
          "primary": true
        },
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 1,
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:9babd184:::EOBJ2:head(29'2 client.4217.0:1 dirty|data_digest s 7 uv 2 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "ec_hash_error"
      ],
      "errors": [],
      "object": {
        "version": 2,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ2"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "osd": 1,
          "primary": true,
          "shard": 0,
          "errors": [
            "missing"
          ]
        },
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:b197b25d:::EOBJ3:head(37'3 client.4251.0:1 dirty|data_digest s 7 uv 3 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "missing"
      ],
      "errors": [],
      "object": {
        "version": 3,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ3"
      }
    },
    {
      "shards": [
        {
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "bad-val",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val3-EOBJ4",
              "name": "_key3-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ],
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "osd": 1,
          "primary": true,
          "shard": 0,
          "errors": [],
          "size": 2048,
          "omap_digest": "0xffffffff",
          "data_digest": "0x04cfa72f",
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-EOBJ4",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val2-EOBJ4",
              "name": "_key2-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ]
        },
        {
          "osd": 2,
          "primary": false,
          "shard": 1,
          "errors": [],
          "size": 2048,
          "omap_digest": "0xffffffff",
          "data_digest": "0x04cfa72f",
          "attrs": [
            {
              "Base64": true,
              "value": "",
              "name": "_"
            },
            {
              "Base64": false,
              "value": "val1-EOBJ4",
              "name": "_key1-EOBJ4"
            },
            {
              "Base64": false,
              "value": "val2-EOBJ4",
              "name": "_key2-EOBJ4"
            },
            {
              "Base64": true,
              "value": "AQEYAAAAAAgAAAAAAAADAAAAL6fPBLB8dlsvp88E",
              "name": "hinfo_key"
            },
            {
              "Base64": true,
              "value": "AwIdAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              "name": "snapset"
            }
          ]
        }
      ],
      "selected_object_info": "3:5e723e06:::EOBJ4:head(45'6 client.4289.0:1 dirty|data_digest s 7 uv 6 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [],
      "errors": [
        "attr_value_mismatch",
        "attr_name_mismatch"
      ],
      "object": {
        "version": 6,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ4"
      }
    },
    {
      "shards": [
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "errors": [],
          "shard": 2,
          "osd": 0,
          "primary": false
        },
        {
          "size": 4096,
          "shard": 0,
          "errors": [
            "size_mismatch_oi",
            "ec_size_error",
            "obj_size_oi_mismatch"
          ],
          "osd": 1,
          "primary": true
        },
        {
          "data_digest": "0x04cfa72f",
          "omap_digest": "0xffffffff",
          "size": 2048,
          "shard": 1,
          "errors": [],
          "osd": 2,
          "primary": false
        }
      ],
      "selected_object_info": "3:8549dfb5:::EOBJ5:head(65'7 client.4441.0:1 dirty|data_digest s 7 uv 7 dd 2ddbf8f5 alloc_hint [0 0 0])",
      "union_shard_errors": [
        "size_mismatch_oi",
        "ec_size_error",
        "obj_size_oi_mismatch"
      ],
      "errors": [
        "size_mismatch"
      ],
      "object": {
        "version": 7,
        "snap": "head",
        "locator": "",
        "nspace": "",
        "name": "EOBJ5"
      }
    }
  ],
  "epoch": 0
}
EOF

    fi

    jq "$jqfilter" $dir/json | python -c "$sortkeys" | sed -e "$sedfilter" > $dir/csjson
    diff ${DIFFCOLOPTS} $dir/checkcsjson $dir/csjson || test $getjson = "yes" || return 1
    if test $getjson = "yes"
    then
      if [ "$allow_overwrites" = "true" ]
      then
        num=4
      else
        num=5
      fi
      jq '.' $dir/json > save${num}.json
    fi

    if which jsonschema > /dev/null;
    then
      jsonschema -i $dir/json $CEPH_ROOT/doc/rados/command/list-inconsistent-obj.json || return 1
    fi

    rados rmpool $poolname $poolname --yes-i-really-really-mean-it
    teardown $dir || return 1
}

function TEST_corrupt_scrub_erasure_appends() {
    corrupt_scrub_erasure $1 false
}

function TEST_corrupt_scrub_erasure_overwrites() {
    if [ "$use_ec_overwrite" = "true" ]; then
        corrupt_scrub_erasure $1 true
    fi
}

#
# Test to make sure that a periodic scrub won't cause deep-scrub info to be lost
#
function TEST_periodic_scrub_replicated() {
    local dir=$1
    local poolname=psr_pool
    local objname=POBJ

    setup $dir || return 1
    run_mon $dir a --osd_pool_default_size=2 || return 1
    run_mgr $dir x || return 1
    local ceph_osd_args="--osd-scrub-interval-randomize-ratio=0 --osd-deep-scrub-randomize-ratio=0 "
    ceph_osd_args+="--osd_scrub_backoff_ratio=0"
    run_osd $dir 0 $ceph_osd_args || return 1
    run_osd $dir 1 $ceph_osd_args || return 1
    create_rbd_pool || return 1
    wait_for_clean || return 1

    create_pool $poolname 1 1 || return 1
    wait_for_clean || return 1

    local osd=0
    add_something $dir $poolname $objname scrub || return 1
    local primary=$(get_primary $poolname $objname)
    local pg=$(get_pg $poolname $objname)

    # Add deep-scrub only error
    local payload=UVWXYZ
    echo $payload > $dir/CORRUPT
    # Uses $ceph_osd_args for osd restart
    objectstore_tool $dir $osd $objname set-bytes $dir/CORRUPT || return 1

    # No scrub information available, so expect failure
    set -o pipefail
    !  rados list-inconsistent-obj $pg | jq '.' || return 1
    set +o pipefail

    pg_deep_scrub $pg || return 1

    # Make sure bad object found
    rados list-inconsistent-obj $pg | jq '.' | grep -q $objname || return 1

    flush_pg_stats
    local last_scrub=$(get_last_scrub_stamp $pg)
    # Fake a schedule scrub
    CEPH_ARGS='' ceph --admin-daemon $(get_asok_path osd.${primary}) \
             trigger_scrub $pg || return 1
    # Wait for schedule regular scrub
    wait_for_scrub $pg "$last_scrub"

    # It needed to be upgraded
    grep -q "Deep scrub errors, upgrading scrub to deep-scrub" $dir/osd.${primary}.log || return 1

    # Bad object still known
    rados list-inconsistent-obj $pg | jq '.' | grep -q $objname || return 1

    # Can't upgrade with this set
    ceph osd set nodeep-scrub
    # Let map change propagate to OSDs
    flush pg_stats
    sleep 5

    # Fake a schedule scrub
    CEPH_ARGS='' ceph --admin-daemon $(get_asok_path osd.${primary}) \
             trigger_scrub $pg || return 1
    # Wait for schedule regular scrub
    # to notice scrub and skip it
    local found=false
    for i in $(seq 14 -1 0)
    do
      sleep 1
      ! grep -q "Regular scrub skipped due to deep-scrub errors and nodeep-scrub set" $dir/osd.${primary}.log || { found=true ; break; }
      echo Time left: $i seconds
    done
    test $found = "true" || return 1

    # Bad object still known
    rados list-inconsistent-obj $pg | jq '.' | grep -q $objname || return 1

    flush_pg_stats
    # Request a regular scrub and it will be done
    pg_scrub $pg
    grep -q "Regular scrub request, deep-scrub details will be lost" $dir/osd.${primary}.log || return 1

    # deep-scrub error is no longer present
    rados list-inconsistent-obj $pg | jq '.' | grep -qv $objname || return 1
}


main osd-scrub-repair "$@"

# Local Variables:
# compile-command: "cd ../.. ; make -j4 && \
#    test/osd/osd-scrub-repair.sh # TEST_corrupt_and_repair_replicated"
# End:
