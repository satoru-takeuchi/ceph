// -*- mode:C++; tab-width:8; c-basic-offset:2; indent-tabs-mode:t -*- 
// vim: ts=8 sw=2 smarttab
/*
 * Ceph - scalable distributed file system
 *
 * Copyright (C) 2004-2006 Sage Weil <sage@newdream.net>
 *
 * This is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License version 2.1, as published by the Free Software 
 * Foundation.  See file COPYING.
 * 
 */


#ifndef __OBJECTSTORE_H
#define __OBJECTSTORE_H

#include "include/types.h"
#include "include/Context.h"
#include "include/buffer.h"
#include "include/pobject.h"

#include "include/Distribution.h"

#include <sys/stat.h>

#ifdef DARWIN
#include <sys/statvfs.h>
#else
#include <sys/vfs.h>    /* or <sys/statfs.h> */
#endif /* DARWIN */

#include <list>
using std::list;

#ifndef MIN
# define MIN(a,b) ((a) < (b) ? (a):(b))
#endif

/*
 * low-level interface to the local OSD file system
 */



class ObjectStore {
public:


  class FragmentationStat {
  public:
    int total;
    int num_extent;
    int avg_extent;
    map<int,int> extent_dist;          // powers of two
    map<int,int> extent_dist_sum;          // powers of two

    float avg_extent_per_object;
    int avg_extent_jump;  // avg distance bweteen consecutive extents

    int total_free;
    int num_free_extent;
    int avg_free_extent;
    map<int,int> free_extent_dist;     // powers of two
    map<int,int> free_extent_dist_sum;     // powers of two
  };
  
  

  /*********************************
   * transaction
   */
  class Transaction {
  public:
    static const int OP_READ =          1;  // oid, offset, len, pbl
    static const int OP_STAT =          2;  // oid, pstat
    static const int OP_GETATTR =       3;  // oid, attrname, pattrval
    static const int OP_GETATTRS =      4;  // oid, pattrset

    static const int OP_WRITE =        10;  // oid, offset, len, bl
    static const int OP_ZERO =         11;  // oid, offset, len
    static const int OP_TRUNCATE =     12;  // oid, len
    static const int OP_REMOVE =       13;  // oid
    static const int OP_SETATTR =      14;  // oid, attrname, attrval
    static const int OP_SETATTRS =     15;  // oid, attrset
    static const int OP_RMATTR =       16;  // oid, attrname
    static const int OP_CLONE =        17;  // oid, newoid

    static const int OP_TRIMCACHE =    18;  // oid, offset, len

    static const int OP_MKCOLL =       20;  // cid
    static const int OP_RMCOLL =       21;  // cid
    static const int OP_COLL_ADD =     22;  // cid, oid
    static const int OP_COLL_REMOVE =  23;  // cid, oid
    static const int OP_COLL_SETATTR = 24;  // cid, attrname, attrval
    static const int OP_COLL_RMATTR =  25;  // cid, attrname
    static const int OP_COLL_SETATTRS = 26;  // cid, attrset

  private:
    list<int8_t> ops;
    list<bufferlist> bls;
    list<pobject_t> oids;
    list<coll_t> cids;
    list<int64_t> lengths;
    list<const char*> attrnames;
    list<string> attrnames2;

    // for reads only (not encoded)
    list<bufferlist*> pbls;
    list<struct stat*> psts;
    list< pair<void*,int*> > pattrvals;
    list< map<string,bufferptr>* > pattrsets;

  public:
    bool have_op() {
      return !ops.empty();
    }
    int get_num_ops() { return ops.size(); }
    int get_op() {
      int op = ops.front();
      ops.pop_front();
      return op;
    }
    void get_bl(bufferlist& bl) {
      bl.claim(bls.front());
      bls.pop_front();
    }
    void get_oid(pobject_t& oid) {
      oid = oids.front();
      oids.pop_front();
    }
    void get_cid(coll_t& cid) {
      cid = cids.front();
      cids.pop_front();
    }
    void get_length(off_t& len) {
      len = lengths.front();
      lengths.pop_front();
    }
    void get_attrname(const char * &p) {
      p = attrnames.front();
      attrnames.pop_front();
    }
    void get_pbl(bufferlist* &pbl) {
      pbl = pbls.front();
      pbls.pop_front();
    }
    void get_pstat(struct stat* &pst) {
      pst = psts.front();
      psts.pop_front();
    }
    void get_pattrval(pair<void*,int*>& p) {
      p = pattrvals.front();
      pattrvals.pop_front();
    }
    void get_pattrset(map<string,bufferptr>* &ps) {
      ps = pattrsets.front();
      pattrsets.pop_front();
    }
      

    void read(coll_t cid, pobject_t oid, off_t off, size_t len, bufferlist *pbl) {
      int op = OP_READ;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      lengths.push_back(off);
      lengths.push_back(len);
      pbls.push_back(pbl);
    }
    void stat(coll_t cid, pobject_t oid, struct stat *st) {
      int op = OP_STAT;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      psts.push_back(st);
    }
    void getattr(coll_t cid, pobject_t oid, const char* name, void* val, int *plen) {
      int op = OP_GETATTR;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      attrnames.push_back(name);
      pattrvals.push_back(pair<void*,int*>(val,plen));
    }
    void getattrs(coll_t cid, pobject_t oid, map<string,bufferptr>& aset) {
      int op = OP_GETATTRS;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      pattrsets.push_back(&aset);
    }

    void write(coll_t cid, pobject_t oid, off_t off, size_t len, const bufferlist& bl) {
      int op = OP_WRITE;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      lengths.push_back(off);
      lengths.push_back(len);
      bls.push_back(bl);
    }
    void zero(coll_t cid, pobject_t oid, off_t off, size_t len) {
      int op = OP_ZERO;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      lengths.push_back(off);
      lengths.push_back(len);
    }
    void trim_from_cache(coll_t cid, pobject_t oid, off_t off, size_t len) {
      int op = OP_TRIMCACHE;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      lengths.push_back(off);
      lengths.push_back(len);
    }
    void truncate(coll_t cid, pobject_t oid, off_t off) {
      int op = OP_TRUNCATE;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      lengths.push_back(off);
    }
    void remove(coll_t cid, pobject_t oid) {
      int op = OP_REMOVE;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
    }
    void setattr(coll_t cid, pobject_t oid, const char* name, const void* val, int len) {
      int op = OP_SETATTR;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      attrnames.push_back(name);
      //attrvals.push_back(pair<const void*,int>(val,len));
      bufferlist bl;
      bl.append((char*)val,len);
      bls.push_back(bl);
    }
    void setattrs(coll_t cid, pobject_t oid, map<string,bufferptr>& attrset) {
      int op = OP_SETATTRS;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      pattrsets.push_back(&attrset);
    }
    void rmattr(coll_t cid, pobject_t oid, const char* name) {
      int op = OP_RMATTR;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      attrnames.push_back(name);
    }
    void clone(coll_t cid, pobject_t oid, pobject_t noid) {
      int op = OP_CLONE;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
      oids.push_back(noid);
    }
    void create_collection(coll_t cid) {
      int op = OP_MKCOLL;
      ops.push_back(op);
      cids.push_back(cid);
    }
    void remove_collection(coll_t cid) {
      int op = OP_RMCOLL;
      ops.push_back(op);
      cids.push_back(cid);
    }
    void collection_add(coll_t cid, coll_t ocid, pobject_t oid) {
      int op = OP_COLL_ADD;
      ops.push_back(op);
      cids.push_back(cid);
      cids.push_back(ocid);
      oids.push_back(oid);
    }
    void collection_remove(coll_t cid, pobject_t oid) {
      int op = OP_COLL_REMOVE;
      ops.push_back(op);
      cids.push_back(cid);
      oids.push_back(oid);
    }
    void collection_setattr(coll_t cid, const char* name, const void* val, int len) {
      int op = OP_COLL_SETATTR;
      ops.push_back(op);
      cids.push_back(cid);
      attrnames.push_back(name);
      bufferlist bl;
      bl.append((char*)val, len);
      bls.push_back(bl);
    }
    void collection_rmattr(coll_t cid, const char* name) {
      int op = OP_COLL_RMATTR;
      ops.push_back(op);
      cids.push_back(cid);
      attrnames.push_back(name);
    }
    void collection_setattrs(coll_t cid, map<string,bufferptr>& aset) {
      int op = OP_COLL_SETATTRS;
      ops.push_back(op);
      cids.push_back(cid);
      pattrsets.push_back(&aset);
    }

    // etc.
    Transaction() {}
    Transaction(bufferlist::iterator &p) { decode(p); }
    Transaction(bufferlist &bl) { 
      bufferlist::iterator p = bl.begin();
      decode(p); 
    }

    void encode(bufferlist& bl) const {
      ::encode(ops, bl);
      ::encode(bls, bl);
      ::encode(oids, bl);
      ::encode(cids, bl);
      ::encode(lengths, bl);
      ::encode(attrnames, bl);
    }
    void decode(bufferlist::iterator &bl) {
      ::decode(ops, bl);
      ::decode(bls, bl);
      ::decode(oids, bl);
      ::decode(cids, bl);
      ::decode(lengths, bl);
      ::decode(attrnames2, bl);
      for (list<string>::iterator p = attrnames2.begin();
	   p != attrnames2.end();
	   ++p)
	attrnames.push_back((*p).c_str());
    }
  };

  /*
   * these stubs should be implemented if we want to use the
   * apply_transaction() below and we want atomic transactions.
   */
  virtual int transaction_start() { return 0; }
  virtual void transaction_end(int id) { }
  virtual unsigned apply_transaction(Transaction& t, Context *onsafe=0) {
    // non-atomic implementation
    int id = transaction_start();
    while (t.have_op()) {
      int op = t.get_op();
      switch (op) {
      case Transaction::OP_READ:
        {
	  coll_t cid;
          pobject_t oid;
          off_t offset, len;
	  t.get_cid(cid);
	  t.get_oid(oid);
	  t.get_length(offset);
	  t.get_length(len);
          bufferlist *pbl;
	  t.get_pbl(pbl);
          read(cid, oid, offset, len, *pbl);
        }
        break;
      case Transaction::OP_STAT:
        {
	  coll_t cid;
	  t.get_cid(cid);
          pobject_t oid;
	  t.get_oid(oid);
          struct stat *st;
	  t.get_pstat(st);
          stat(cid, oid, st);
        }
        break;
      case Transaction::OP_GETATTR:
        {
       	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          const char *attrname;
	  t.get_attrname(attrname);
          pair<void*,int*> pattrval;
	  t.get_pattrval(pattrval);
          *pattrval.second = getattr(cid, oid, attrname, pattrval.first, *pattrval.second);
        }
        break;
      case Transaction::OP_GETATTRS:
        {
	  coll_t cid;
	  t.get_cid(cid);
          pobject_t oid;
	  t.get_oid(oid);
          map<string,bufferptr> *pset;
	  t.get_pattrset(pset);
          getattrs(cid, oid, *pset);
        }
        break;

      case Transaction::OP_WRITE:
        {
 	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          off_t offset, len;
	  t.get_length(offset);
	  t.get_length(len);
          bufferlist bl;
	  t.get_bl(bl);
          write(cid, oid, offset, len, bl, 0);
        }
        break;

      case Transaction::OP_ZERO:
        {
  	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          off_t offset, len;
	  t.get_length(offset);
	  t.get_length(len);
          zero(cid, oid, offset, len, 0);
        }
        break;

      case Transaction::OP_TRIMCACHE:
        {
	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          off_t offset, len;
	  t.get_length(offset);
	  t.get_length(len);
          trim_from_cache(cid, oid, offset, len);
        }
        break;

      case Transaction::OP_TRUNCATE:
        {
  	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          off_t len;
	  t.get_length(len);
          truncate(cid, oid, len, 0);
        }
        break;

      case Transaction::OP_REMOVE:
        {
 	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          remove(cid, oid, 0);
        }
        break;

      case Transaction::OP_SETATTR:
        {
 	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          const char *attrname;
	  t.get_attrname(attrname);
          bufferlist bl;
	  t.get_bl(bl);
          setattr(cid, oid, attrname, bl.c_str(), bl.length(), 0);
        }
        break;
      case Transaction::OP_SETATTRS:
        {
	  coll_t cid;
	  t.get_cid(cid);
          pobject_t oid;
	  t.get_oid(oid);
          map<string,bufferptr> *pattrset;
	  t.get_pattrset(pattrset);
          setattrs(cid, oid, *pattrset, 0);
        }
        break;

      case Transaction::OP_RMATTR:
        {
  	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          const char *attrname;
	  t.get_attrname(attrname);
          rmattr(cid, oid, attrname, 0);
        }
        break;

      case Transaction::OP_CLONE:
	{
  	  coll_t cid;
	  t.get_cid(cid);
	  pobject_t oid;
	  t.get_oid(oid);
          pobject_t noid;
	  t.get_oid(noid);
	  clone(cid, oid, noid);
	}
	break;

      case Transaction::OP_MKCOLL:
        {
          coll_t cid;
	  t.get_cid(cid);
          create_collection(cid, 0);
        }
        break;

      case Transaction::OP_RMCOLL:
        {
          coll_t cid;
	  t.get_cid(cid);
          destroy_collection(cid, 0);
        }
        break;

      case Transaction::OP_COLL_ADD:
        {
          coll_t cid, ocid;
	  t.get_cid(cid);
	  t.get_cid(ocid);
          pobject_t oid;
	  t.get_oid(oid);
          collection_add(cid, ocid, oid, 0);
        }
        break;

      case Transaction::OP_COLL_REMOVE:
        {
          coll_t cid;
	  t.get_cid(cid);
          pobject_t oid;
	  t.get_oid(oid);
          collection_remove(cid, oid, 0);
        }
        break;

      case Transaction::OP_COLL_SETATTR:
        {
          coll_t cid;
	  t.get_cid(cid);
          const char *attrname;
	  t.get_attrname(attrname);
          bufferlist bl;
	  t.get_bl(bl);
          collection_setattr(cid, attrname, bl.c_str(), bl.length(), 0);
        }
        break;

      case Transaction::OP_COLL_RMATTR:
        {
          coll_t cid;
	  t.get_cid(cid);
          const char *attrname;
	  t.get_attrname(attrname);
          collection_rmattr(cid, attrname, 0);
        }
        break;


      default:
        cerr << "bad op " << op << std::endl;
        assert(0);
      }
    }
    transaction_end(id);

    if (onsafe) sync(onsafe);

    return 0;  // FIXME count errors
  }

  /*********************************************/



 public:
  ObjectStore() {}
  virtual ~ObjectStore() {}

  // mgmt
  virtual int mount() = 0;
  virtual int umount() = 0;
  virtual int mkfs() = 0;  // wipe

  virtual int statfs(struct statfs *buf) = 0;

  // objects
  virtual int pick_object_revision_lt(coll_t cid, pobject_t& oid) = 0;
  virtual bool exists(coll_t cid, pobject_t oid) = 0;                   // useful?
  virtual int stat(coll_t cid, pobject_t oid, struct stat *st) = 0;     // struct stat?
  virtual int remove(coll_t cid, pobject_t oid, Context *onsafe=0) = 0;
  virtual int truncate(coll_t cid, pobject_t oid, off_t size, Context *onsafe=0) = 0;
  
  virtual int read(coll_t cid, pobject_t oid, off_t offset, size_t len, bufferlist& bl) = 0;
  virtual int write(coll_t cid, pobject_t oid, off_t offset, size_t len, const bufferlist& bl, Context *onsafe) = 0;
  virtual int zero(coll_t cid, pobject_t oid, off_t offset, size_t len, Context *onsafe) {
    // write zeros.. yuck!
    bufferptr bp(len);
    bufferlist bl;
    bl.push_back(bp);
    return write(cid, oid, offset, len, bl, onsafe);
  }
  virtual void trim_from_cache(coll_t cid, pobject_t oid, off_t offset, size_t len) = 0; //{ }
  virtual int is_cached(coll_t cid, pobject_t oid, off_t offset, size_t len) = 0;  //{ return -1; }

  virtual int setattr(coll_t cid, pobject_t oid, const char *name,
                      const void *value, size_t size,
                      Context *onsafe=0) {return 0;} //= 0;
  virtual int setattrs(coll_t cid, pobject_t oid, map<string,bufferptr>& aset,
                      Context *onsafe=0) {return 0;} //= 0;
  virtual int getattr(coll_t cid, pobject_t oid, const char *name,
                      void *value, size_t size) {return 0;} //= 0;
  virtual int getattrs(coll_t cid, pobject_t oid, map<string,bufferptr>& aset) {return 0;};

  virtual int rmattr(coll_t cid, pobject_t oid, const char *name,
                     Context *onsafe=0) {return 0;}

  virtual int clone(coll_t cid, pobject_t oid, pobject_t noid) {
    return -1;
  }
  
  virtual int get_object_collections(coll_t cid, pobject_t oid, set<coll_t>& ls) { return -1; }

  //virtual int listattr(pobject_t oid, char *attrs, size_t size) {return 0;} //= 0;
  
  // collections
  virtual int list_collections(list<coll_t>& ls) = 0;
  virtual int create_collection(coll_t c, Context *onsafe=0) = 0;
  virtual int destroy_collection(coll_t c, Context *onsafe=0) = 0;
  virtual bool collection_exists(coll_t c) = 0;
  virtual int collection_add(coll_t c, coll_t ocid, pobject_t o, Context *onsafe=0) = 0;
  virtual int collection_remove(coll_t c, pobject_t o, Context *onsafe=0) = 0;
  virtual int collection_list(coll_t c, list<pobject_t>& o) = 0;
  virtual int collection_setattr(coll_t cid, const char *name,
                                 const void *value, size_t size,
                                 Context *onsafe=0) = 0;
  virtual int collection_rmattr(coll_t cid, const char *name,
                                Context *onsafe=0) = 0;
  virtual int collection_getattr(coll_t cid, const char *name,
                                 void *value, size_t size) = 0;

  virtual int collection_getattrs(coll_t cid, map<string,bufferptr> &aset) = 0;
  virtual int collection_setattrs(coll_t cid, map<string,bufferptr> &aset) = 0;


  //virtual int collection_listattr(coll_t cid, char *attrs, size_t size) {return 0;} //= 0;
  
  virtual void sync(Context *onsync) {}
  virtual void sync() {}
  
  
  virtual void _fake_writes(bool b) {};

  virtual void _get_frag_stat(FragmentationStat& st) {};
  
};


#endif
