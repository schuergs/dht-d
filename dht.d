/**
 * dht-d: Distributed hash table (DHT) for "mainline" DHT 
 *
 * Copyright (c) 2016-2018 Stefan Schuerger
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 */

//
// version statistics: Collect data transfer & blacklist statistics for each network
// version disable_blacklisting: Do not reject blacklisted entries
// 

module dht;

import std.socket               : Socket, SocketFlags, Address, InternetAddress, Internet6Address, AddressFamily, UnknownAddressReference;
import std.format               : formattedWrite, formattedRead;
import std.string               : representation, sformat;
import std.conv                 : hexString, to;
import std.array                : array, appender, join;
import std.ascii                : isPrintable, isDigit;
import std.algorithm            : sort, find, topN, min, max, map;
import std.random               : uniform;
import std.experimental.logger  : Logger, FileLogger;
import std.digest.md            : MD5;
import std.digest.crc;
import core.stdc.time           : time, time_t;
import core.stdc.stdlib         : strtol;
import core.stdc.string         : memcmp;
import core.sys.posix.arpa.inet : htons, htonl, ntohs, ntohl;
import core.sys.posix.netinet.in_ : sockaddr_in, sockaddr_in6; 


static Logger fLog;

// Comment this out to remove blacklisting warnings in log
//version = warnBlacklist;

enum DHTMessageType : short {
    unknown       = 0,
    error         = 1,
    reply         = 2,
    ping          = 3,
    find_node     = 4,
    get_peers     = 5,
    announce_peer = 6,
}

enum DHTProtocol : short {
    nowant = 0, // = native protocol
    want4  = 1,
    want6  = 2,
    want46 = 3,
}

class DHT {
    // Global parameters for the DHT behaviour
    // This does not contain values defined by the protocol (e.g., ID length)
    struct globals_t {
        uint bucket_size = 8; // The size of our buckets
        uint bucket_max_ping_count = 3;                     // Considered "dead" after n unsuccessful pings
        uint bucket_max_ping_time = 15;                     // Time between pings
        uint bucket_max_age = 600;                          // How old may a bucket become before bucket maintenance?
        uint bucket_max_num = 999;                          // The maximum depth of our routing table
        uint bucket_cache_size = 8;                         // Size of each bucket's cache
	uint bucket_lock_good_id_nodes = 3;                 // The minimum number of good nodes with trusted ID to lock bucket
	uint bucket_unlock_nodes = 2;                       // If a locked bucket falls to 2 nodes or below, unlock it
        uint junk_honeypot_bits = 31;                       // Number of common bits for detecting a "honeypot" peer
        uint junk_seen_addresses_max_age = 3600;            // Expire seen entries
        uint junk_blacklist_addresses_max_age = 3600;       // Expire blacklisted entries
        uint save_top_n = 4;                                // Oldest n nodes per bucket to save
        uint search_expiry = 900;                           // Delete a search
        uint search_bucket_size = 14;                       // Max number of results carried forward
        uint search_bucket_relevant = 8;                    // Max number of results considered
        uint search_parallel_queries = 3;                   // Number of queries in parallel
        uint search_max_ping_time = 2;                      // Wait before next ping
        uint search_boot_bucket_min = 4;                    // Min fill of bucket in boot search
        uint scheduler_check_bucket_lock = 60;              // Lockdown of buckets for good IDs
        uint scheduler_expire_buckets = 60;                 // Service job to expire bucket entries
        uint scheduler_expire_storage = 60;                 // Service job to expire storage
        uint scheduler_expire_searches = 60;                // Service job to expire searches
        uint scheduler_expire_seen_addresses = 900;         // Service job to expire address memory
        uint scheduler_neighbourhood_maintenance = 5;       // Service job to explore neighbourhood
        uint scheduler_neighbourhood_maintenance_late = 60; // Later frequency 
        uint scheduler_neighbourhood_maintenance_late_when = 600; // Run time of DHT after which late frequency is chosen
        uint scheduler_bucket_maintenance = 5;              // Service job to refresh bucket entries
        uint scheduler_push_searches = 5;                   // Move searches forward
        uint scheduler_rehash = 3600;                       // Re-hash all internal tables
        uint storage_return_results = 50;                   // Max addresses to return to get_peers query
        uint storage_expiry = 1800;                         // Delete a storage address after
        uint sybil_max_num_ids = 3;                         // How many IDs an address may display before considered a sybil
        uint throttling_max_bucket = 400;                   // Maximum threshold tokens
        uint throttling_per_sec = 100;                      // Throttling per second	
    };
    
    private static DHT singleton = null;
    
    public static globals_t globals;
    public static time_t now_t; // updated regularly
    private static time_t starttime;
    alias DHTBucketList = DoubleList!DHTBucket;
    public static DHTProtocol want = DHTProtocol.nowant;

    public static DHTInfo info, info6;

    protected MessageWM wm;
    alias callback_t = void function(CallbackType, DHTId, Address[]);
    private callback_t callback;
    protected Scheduler!ScheduleType scheduler;
    private static ubyte[] secret, secret_old;
    private time_t last_throttling_check;
    private uint throttling_tokens;

    // Protection against Sybil attacks
    private SeenAddress[ubyte[]] seen_addresses;
    private SybilWatchAddress[ubyte[]] sybil_watch_addresses;
    private static BlacklistAddress[ubyte[]] blacklisted;
    
    
    // per-protocol struct (IPV4 + IPV6)
    // Effectively each protocol is a separate DHT with some data interchange
    // (find node, get peers)
    struct DHTInfo {
        Socket s;
        DHTBucketList buckets;
        DHTBucket my_bucket;
        DHTNode[DHTId] bucket_nodes;
        idStorage*[DHTId] storage;
        Search*[DHTtid] searches;
	DHTId myid; // Due to security extensions IPv4 and IPv6 may have different IDs.
	// IP and IP voting
	ubyte[] own_ip = [127,0,0,1]; // Dummy default address
	bool ip_voting=false;
	const uint ip_voting_size = 8;
	uint ip_voting_num=0;
	ubyte[][ip_voting_size] own_ip_vote;
	
        bool is_v6;
	uint parsed_recv = 0;               // messages successfully parsed - also needed for num_nodes

        void reset_buckets(){
	    DHTBucket b;
	    if(buckets.num == 0){
	        b = new DHTBucket(DHTId.zero, &this);
                buckets.addBack(b);
	    } else {
	        b = buckets.first;
		b.next = null;
		buckets.last = b;
		buckets.num = 1;
		b.nodes.reset();
	    }
	    bucket_nodes.clear;
            my_bucket = b;
	}    

        version (statistics) {
            ulong data_send_net = 0, // Raw data statistics; gross = w/ IP+UDP header  
            data_send_gross = 0, data_recv_net = 0,
                data_recv_gross = 0, data_send_num = 0, data_recv_num = 0;
            static const ulong header_size4 = 20, header_size6 = 48;
            @property ulong header_size() {
                return is_v6 ? header_size6 : header_size4;
            }

            uint blacklisted_recv = 0,       // Messages from blacklisted nodes
            throttled_recv = 0,              // Messages discarded by throttling
            nodes_recv = 0,                  // Nodes received (get_peers, find_node)
            blacklisted_nodes_recv = 0,      // Nodes received which are blacklisted
            nodes_from_blacklisted_recv = 0; // Nodes received from blacklisted senders
        }
        @property string toString() {
            static char[512] buf;
            if (s is null)
                return "";
            auto a = appender!string();
	    a ~= "ID: ";
	    a ~= myid.toString;
	    a ~= ' ';
	    a ~= to_address(own_ip).toAddrString();
	    a ~= '\n';
            a ~= (is_v6 ? "IPv6" : "IPv4") ~ " Buckets:\n";
            for (auto b = buckets.first; b; b = b.next)
                a ~= b.toString;

            a ~= (is_v6 ? "IPv6" : "IPv4") ~ " Searches:\n";
            foreach (tid; searches.keys.dup.sort!"a.tkey < b.tkey") {
                a ~= searches[tid].toString();
            }
            a ~= (is_v6 ? "IPv6" : "IPv4") ~ " Storage:\n";
            auto ks = storage.keys.dup;
            sort(ks);
            foreach (k; ks) {
                a ~= k.toString();
                a ~= " ";
                a ~= storage[k].toString(is_v6);
                a ~= "\n";
            }
 
            version (statistics) {
            	double delta_t = now - starttime;
                a ~= '\n';
                a ~= (is_v6 ? "IPv6" : "IPv4") ~ " Statistics:\n";
                	
                formattedWrite(a,"Sent: %d messages, %d bytes net, %d bytes gross (%.1f / %.0f / %.0f per sec)\n",
                    data_send_num, data_send_net, data_send_gross, 
                    data_send_num/delta_t, data_send_net/delta_t, data_send_gross/delta_t);
                	
                formattedWrite(a,"Received: %d messages, %d bytes net, %d bytes gross (%.1f / %.0f / %.0f per sec)\n",
                    data_recv_num, data_recv_net, data_recv_gross, 
                    data_recv_num/delta_t, data_recv_net/delta_t, data_recv_gross/delta_t);

                formattedWrite(a, "  Throttling: %d of %d parsed (%.2f%%)\n",
                    throttled_recv, parsed_recv,
                    100.0 * (to!double(throttled_recv) / to!double(parsed_recv)));

	        a ~= (is_v6 ? "IPv6" : "IPv4") ~ " Blacklist:\n";
                formattedWrite(a,
                    "  Blacklisted nodes in messages: %d of %d (%.2f%%)\n",
                    blacklisted_nodes_recv, nodes_recv,
                    100.0 * (to!double(blacklisted_nodes_recv) / to!double(nodes_recv)));
                formattedWrite(a,
                    "  Nodes from blacklisted senders in messages: %d of %d (%.2f%%)\n",
                    nodes_from_blacklisted_recv, nodes_recv,
                    100.0 * (to!double(nodes_from_blacklisted_recv) / to!double(nodes_recv)));
 
           }
            return a.data;
        }

    }

    // Working memory for incoming message
    private struct MessageWM {
        DHTMessageType message;
        ubyte[] tid; // This could be some other client's TID format, so can't use DHTtid
        DHTId id, info_hash, target;
        ubyte[] nodes, nodes6, token;
        ushort port;
        ubyte[] values, values6;
        DHTProtocol want;
        ubyte[] ttid;
	ubyte[] own_ip;
        string toString() {
            return "message: " ~ to!string(message) ~ 
                "\ntid: " ~ (tid.length == 4 ? DHTtid(tid).toString : to!string(tid)) ~ 
                "\nid: " ~ id.toString() ~ 
                "\ninfo_hash: " ~ info_hash.toString() ~ 
                "\ntarget: " ~ target.toString() ~ 
                "\nnodes: (" ~ to!string(nodes.length / 26) ~ "+" ~ to!string(nodes6.length / 38) ~ ")" ~ 
                "\nport: " ~ to!string(port) ~ 
                "\nwant: " ~ to!string(want) ~ 
                "\ntoken: " ~ to!string(token.length) ~ 
                " values: " ~ to!string(values.length) ~ " values6: " ~ to!string(values6.length);
        }
    }

    private struct idStorage {
        DoubleList!idAddressStorage addresses;
        idAddressStorage*[AddressBlob] addresshash;
        idAddressStorage* walker = null;
        @property string toString(bool is_v6) {
            auto a = appender!string();
            a ~= to!string(addresses.num);
            a ~= ": ";
            for (auto s = addresses.first; s; s = s.next) {
                a ~= s.toString(is_v6);
                if (s.next)
                    a ~= ", ";
            }
            return a.data;
        }
    };

    private struct idAddressStorage {
        idAddressStorage* prev, next;
        AddressBlob address;
        time_t age;
        @property string toString(bool is_v6) {
            return to_address(is_v6 ? address.blob6 : address.blob4).toString() ~ " age: " ~ to_ascii(
                age);
        }
    };

    protected struct Search {
        enum Status : byte {
            searching = 0,
            announcing = 1,
            done = 2,
        };
        DHTId info_hash;
        DHTtid tid;
        SearchNode*[] snodes;
        SearchNode*[DHTId] snodes_seen;
        Address[ubyte[]] found_peers;
        time_t age, status_since;
        uint queries, responses, numnodes, numpeers;
        ushort port;
        bool is_boot_search = false;
        Status status;
        this(DHTId ihash, DHTtid itid, ushort p) {
            info_hash = ihash;
            tid = itid;
            port = p;
            age = status_since = now;
            status = Status.searching;
        }

        @property string toString() {
            auto a = appender!string();
            a ~= tid.toString() ~ ": " ~ info_hash.toString() ~ " queries: " ~ to!string(queries) ~ " responses: " ~ 
                to!string(responses) ~ " nodes: " ~ to!string(numnodes) ~ " (" ~ to!string(snodes_seen.length) ~ " unique)" ~
                " peers: " ~ to!string(numpeers) ~ " (" ~ to!string(found_peers.length) ~ " unique)" ~ 
                " age: " ~ to_ascii(age) ~ (is_boot_search ? " (boot search)" : "") ~ 
                " (" ~ to!string(status) ~ " for " ~ to_ascii(status_since) ~ ")\n";
            foreach (sn; snodes)
                a ~= "  " ~ sn.toString(&this) ~ "\n";
            return a.data;
        }

    };

    private struct SearchNode {
        enum Status : byte {
            fresh = 0,
            pinged1 = 1,
            pinged2 = 2,
            pinged3 = 3,
            dead = 4,
            blacklisted = 5,
            replied = -1,
            acked = -2,
        };
        DHTId id;
        DHTId distance;
        Address address;
        ubyte[] token;
        time_t age, last_pinged;
        Status status;
        bool id_matches_ip;

        this(Search* s, DHTId nid, Address a) {
            id = nid;
            distance = id.distance_to(s.info_hash);
            address = a;
            age = DHT.now;
            last_pinged = 0;
            s.snodes_seen[nid] = &this;
            status = Status.fresh;
	    id_matches_ip = is_id_by_ip(id,to_blob(address));
        }

        @property string toString(Search* s) {
            static char[512] buf;

            // Only show blacklisted nodes if statistics are on & blacklisting is disabled.
            version (disable_blacklisting)
                version (statistics)
                    return to!string(sformat(buf,
                        "%s %-47s age: %-6s lp: %-6s %3d bits (%s)%s", id.toString() ~ (id_matches_ip ? "T" : " "),
                        to!string(address), age.to_ascii(),
                        last_pinged.to_ascii(), id.common_bits(s.info_hash),
                        status,
                        is_really_blacklisted(
                            address.addressFamily == AddressFamily.INET ? &DHT.info : &DHT.info6,address) ? 
                            " (in blacklist)" : ""));

            return to!string(sformat(buf,
                "%s %-*s age: %-6s lp: %-6s %3d bits (%s)", id.toString() ~ (id_matches_ip ? "T" : " "),
                address.addressFamily == AddressFamily.INET ? 21 : 47,
                to!string(address), age.to_ascii(), last_pinged.to_ascii(),
                id.common_bits(s.info_hash), status));
        }
    };

    public enum CallbackType {
        unknown = 0,
        search_result_v4,
        search_result_v6,
        search_finished_v4,
        search_finished_v6
    };

    protected enum ScheduleType {
        expire_buckets,
        expire_storage,
        expire_searches,
        expire_seen_addresses,
        neighbourhood_maintenance,
        bucket_maintenance,
        push_searches,
        rehash,
	random_search,
	ping_walker,
	check_bucket_lock,
    };

    /**********************************************************
     * Initialise the DHT.
     * Params:
     *   myID  = The DHT Id of this node
     *   sock4 = a bound IPv4 socket. null for an IPv6-only client.
     *   sock6 = a bound IPv6 socket. null for an IPv4-only client.
     *   callBack = A callback function of void (CallbackType,DHTId,Address[]).
     *              This function will be called when a search returned a result
     *              or is finished.
     * See_Also: callback_t, DHTId
     */

    this(DHTId myID4, DHTId myID6,Socket sock4, Socket sock6, callback_t callBack) {
        assert(singleton is null);
	
	singleton = this;
	
	now_t = time(null);
        starttime = now;
        info.myid = myID4;
        info6.myid = myID6;
        info.s = sock4;
        info6.s = sock6;
        info.reset_buckets();
        info6.reset_buckets();
        info6.is_v6 = true;
	info6.own_ip = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1]; 
        if (sock4)
            want |= DHTProtocol.want4;
        if (sock6)
            want |= DHTProtocol.want6;
        callback = callBack;

        last_throttling_check = now;
        throttling_tokens = globals.throttling_max_bucket;

        scheduler = new Scheduler!ScheduleType();
        scheduler.add(ScheduleType.expire_buckets, () { expire_buckets(); },
            globals.scheduler_expire_buckets, globals.scheduler_expire_buckets, now);
        scheduler.add(ScheduleType.expire_storage, () { expire_storage(); },
            globals.scheduler_expire_storage, globals.scheduler_expire_storage, now);
        scheduler.add(ScheduleType.expire_searches, () { expire_searches(); },
            globals.scheduler_expire_searches, globals.scheduler_expire_searches, now);
        scheduler.add(ScheduleType.expire_seen_addresses, () { expire_seen_addresses(); }, 
            globals.scheduler_expire_seen_addresses, globals.scheduler_expire_seen_addresses,now);
        scheduler.add(ScheduleType.neighbourhood_maintenance, () { neighbourhood_maintenance(); }, 
            globals.scheduler_neighbourhood_maintenance, 0, now);
        scheduler.add(ScheduleType.bucket_maintenance, () {bucket_maintenance(); }, 
            globals.scheduler_bucket_maintenance, globals.scheduler_bucket_maintenance, now);
        scheduler.add(ScheduleType.push_searches, () { push_searches(); },
            globals.scheduler_push_searches, globals.scheduler_push_searches, now);
        scheduler.add(ScheduleType.rehash, () { rehash(); },
            globals.scheduler_rehash, globals.scheduler_rehash + 1, now);
        scheduler.add(ScheduleType.check_bucket_lock, () { check_bucket_lock(); },
            globals.scheduler_check_bucket_lock, globals.scheduler_check_bucket_lock, now);

    }

    //
    // This returns the total number of good, dubious and cached nodes in your DHT.
    // For displaying DHT information in your client, or deciding if to start
    // a search.
    // Checking rincoming is a good indication if your node has a firewall issue.
    
    public uint nodes(uint* rgood = null, uint* rdubious = null, uint* rcached = null, uint* rincoming = null) {
        uint good = 0, dubious = 0, cached = 0, incoming = 0;
	
	foreach(pinfo; [&info,&info6]){
	    incoming += pinfo.parsed_recv;
	    for(auto bucket = pinfo.buckets.first; bucket !is null; bucket = bucket.next){
	        cached += bucket.cache.num;
		for(auto node = bucket.nodes.first; node !is null ; node = node.next)
		    if(node.is_good)
		        good++;
		    else
		        dubious++;
	    }
	}
	
        if(rgood !is null)
	    *rgood = good;
        if(rdubious !is null)
	    *rdubious = dubious;
        if(rcached !is null)
	    *rcached = cached;
        if(rincoming !is null)
	    *rincoming = incoming;
	
	return good + dubious;
    }

    public struct NodeInfo{
        DHTId   id;
	Address address;
	this(DHTId iid, Address iaddress){
	    id = iid;
	    address = iaddress;
	}
    }
    
    //
    // get_nodes returns an array of the oldest good nodes, starting from the deepest bucket.
    // This method should be used to save your routing table.
    alias cond_t = bool function(DHTNode);
    public NodeInfo[] get_nodes(DHTProtocol protocol = DHTProtocol.want46, uint maxnumnodes = 9999,uint per_bucket = globals.save_top_n, cond_t condition = null) {
	
        DHTInfo*[] pchoice;
	if(protocol & DHTProtocol.want4)
	    pchoice ~= &info;
	if(protocol & DHTProtocol.want6)
	    pchoice ~= &info6;
	    
	if(protocol == DHTProtocol.want46)
	    maxnumnodes /= 2; // don't exceed limit
	    
	auto nodes = appender!(NodeInfo[])();
	foreach(pinfo; pchoice){
	    uint numnodes = 0;
	    auto walkleft = pinfo.my_bucket;
	    auto walkright = pinfo.my_bucket.next;
	    
	    while(walkleft !is null || walkright !is null){
	        foreach(bucket; [walkleft, walkright]){
	            if(bucket is null)
		        continue;
		    
                    uint fetched = 0;
                    for(auto node = bucket.nodes.first; node !is null && fetched < per_bucket; node = node.next){
		        if(!node.is_good)
			    continue;
			    
			if(condition !is null && !condition(node))
			    continue;
			
			nodes ~= NodeInfo(node.id, node.address);
		        fetched++;
		        numnodes++;
		        if(numnodes >= maxnumnodes)
		            goto pinfo_done;
		    }
		}
		if(walkleft !is null)
		    walkleft = walkleft.prev;
		if(walkright !is null)
		    walkright = walkright.next;
	    }
	    pinfo_done:
	}
        return nodes.data;        
    }
    
    // Insert a list of previously saved nodes into your routing tables,
    // eagerly splitting buckets.
    public void insert_node(NodeInfo[] nodes){
        foreach(node; nodes)
	    insert_node(node.id, node.address);
    }
    
    // Insert a a previously saved nodes into your routing tables,
    // eagerly splitting buckets.
    public DHTNode insert_node(DHTId id, Address address, bool eager_split=false){
	DHTInfo* pinfo;

	// This is necessary, as some functions as getAddress() return
	// the opaque Address subtype UnknownAddressReference
        address =  address.to_subtype();
        pinfo = (address.addressFamily == AddressFamily.INET6 ? &info6 : &info);
	
	DHTBucket bucket = find_bucket(pinfo,id);
	if(eager_split) // Special case - split faster, using save_top_n - This is for initial loading of buckets
	    while(bucket.nodes.num >= globals.save_top_n){
	        if(pinfo.buckets.num >= globals.bucket_max_num) // No more buckets allowed
		    break;
		else if(bucket is pinfo.my_bucket)
	            pinfo.my_bucket.split();
	        else // other bucket is full - shouldn't happen
	    	    break;
	        
	        bucket = find_bucket(pinfo,id);
	    }
	
	
	while(bucket.nodes.num >= globals.bucket_size){
           if(pinfo.buckets.num >= globals.bucket_max_num) // No more buckets allowed
   	        break;
	    if(bucket is pinfo.my_bucket)
	        pinfo.my_bucket.split();
	    else // other bucket is full - shouldn't happen
		return null;
	    
	    bucket = find_bucket(pinfo,id);
	}
        DHTNode this_node = new DHTNode(id, address, bucket);
        pinfo.bucket_nodes[id] = this_node;
        bucket.nodes.addBack(this_node);
	bucket.age = 0; // trigger bucket maintenance
	return this_node;
    } 
    
    
    override public string toString() @property {
        auto a = appender!string();
	a ~= '\n';
	if(want & DHTProtocol.want4){
	    a ~= "IPv4:\n";
	    a ~= info.toString;
	}
	if(want & DHTProtocol.want6){
	    a ~= "IPv6:\n";
	    a ~= info6.toString;
	}
        a ~= "Sybil watchlist size: " ~ to!string(sybil_watch_addresses.length) ~ "\n";

        a ~= "Blacklist size: " ~ to!string(blacklisted.length) ~ "\n";
        
	a ~= "Blacklisted addresses:\n";

	version(statistics)
            foreach (bk; blacklisted.keys.dup.sort!(
	        // 3-level sort:
	        // 1. hits (descending)
	        // 2. length (IPv4 first)
	        // 3. binary address (ascending)
	        (x, y) {
                    auto xh = blacklisted[x].hits, yh = blacklisted[y].hits;
                    if (xh > yh)
                        return true;
                    else if(xh < yh)
		        return false;
		    else{
		        auto xl = x.length, yl = y.length;
		        if(xl < yl)
		            return true;
		        else if(xl > yl)
		            return false;
		        else
		            return x < y;
		    }
		}
            )) {
	        auto bke = blacklisted[bk];
	        if(bke.hits == 0) continue;
	        auto v4equiv = to_v4(cast(ubyte[]) bk);
                formattedWrite(a, "%6d %-*s%s age: %-6s last seen: %-6s (%s)\n", bke.hits,
                    bk.length == 4 ? 17 : 47,
                    to_address(bk).toString, v4equiv is null ? "" : " = " ~ v4equiv.toString,
                    to_ascii(bke.created), to_ascii(bke.last_seen),
                    bke.why.keys.dup.sort.map!(a => a ~ ":" ~ to!string(bke.why[a])).array.join(", ")
                    );
            }
        else
            foreach (bk; blacklisted.keys.dup.sort!
	        // 2-level sort:
	        // 1. length (IPv4 first)
	        // 2. binary address (ascending)
		"a.length < b.length || (a.length == b.length && a < b)"
            ) {
	        auto bke = blacklisted[bk];
	        auto v4equiv = to_v4(cast(ubyte[]) bk);
                a ~= to_address(bk).toString();
		if(v4equiv !is null)
		    a ~= " = " ~ v4equiv.toString;
                a ~= " last seen: ";
                a ~= to_ascii(bke.last_seen);
		a ~= '\n';
	    }
        a ~= "Total of " ~ to!string(seen_addresses.length) ~ " unique addresses seen";
        return a.data;
    }
    
    public final static DHT get_instance() @property {
        return singleton;
    }
    
    public static @property time_t now() {
        return now_t;
    }

    public void boot(Address a) {
        boot([a]);
    }

    public void boot(Address[] aa) {
        foreach (a; aa){
            fLog.info("Sending boot ping to ", a);
           DHTNode.send_ping(a.addressFamily == AddressFamily.INET6 ? info6.s : info.s, a);
	}
    }

    //
    // Main method: called periodically.
    // If there is an empty buffer, just perform maintenance work
    public void periodic(ubyte[] buf, Address from, out time_t next_event) {
        now_t = time(null);
        if (buf.length) // 
            parse_incoming(buf, from);

        next_event = scheduler.run(now);
    }

    protected void parse_incoming(ubyte[] buf, Address from) {
        bool is_v6 = (from.addressFamily() == AddressFamily.INET6);
        DHTInfo* pinfo = (is_v6 ? &info6 : &info);

        version (statistics) {
            pinfo.data_recv_num++;
            pinfo.data_recv_net += buf.length;
            pinfo.data_recv_gross += buf.length + pinfo.header_size;
        }

        bool parse_ok = parse_message(buf);

        if (!parse_ok || wm.message == DHTMessageType.error)
            return;

        pinfo.parsed_recv++;

        if (is_junk(pinfo, wm.id, from, is_v6, true, "message sender"))
            return;

        if (wm.message != DHTMessageType.reply && apply_throttling) {
            fLog.warning("Throttling applied, incoming message discarded.");
            version (statistics)
                pinfo.throttled_recv++;
            return;
        }

	version(protocol_trace)
	    if(wm.tid.length == 4)
	        fLog.info("Message Type: ", wm.message, " TID=", DHTtid(wm.tid));
            else		    
	        fLog.info("Message Type: ", wm.message);
	

	
        switch (wm.message) {
	
        case DHTMessageType.reply:
            DHTtid thistid;
            if (wm.tid.length == 4)
                thistid = DHTtid(wm.tid);
            else {
            	// This behaviour results in immediate blacklisting.
                version (warnBlacklist)
                    fLog.warning("Broken TID in reply: ", wm.tid, " blacklisting ", wm.id);
                blacklist(from,"Broken TID");
                return;
            }
            fLog.trace("\n\nIncoming ", is_v6 ? "IPV6" : "IPV4", " reply for ",
                thistid, " from ", wm.id);

            new_node(pinfo, wm.id, from, DHTNode.Reliability.replied);

            switch (thistid.tcode) {
            case "pn":
                fLog.info("Pong!");
                break;
            case "fn":
                fLog.info("Find node");
                fLog.info("  Nodes found (", wm.nodes.length / 26, "+",
                    wm.nodes6.length / 38, ")!");
                version (statistics)
                    if (is_really_blacklisted(from)) {
                        DHT.info.nodes_from_blacklisted_recv += wm.nodes.length / 26;
                        DHT.info6.nodes_from_blacklisted_recv += wm.nodes6.length / 38;
                    }

                while (wm.nodes.length > 0) {
                    version (statistics) {
                        DHT.info.nodes_recv++;
                        if (is_really_blacklisted(wm.nodes[20 .. 26]))
                            DHT.info.blacklisted_nodes_recv++;
                    }
                    new_node(DHTId(wm.nodes[0 .. 20]), wm.nodes[20 .. 26], DHTNode.Reliability.dubious);
                    wm.nodes = wm.nodes[26 .. $];
                }
                while (wm.nodes6.length > 0) {
                    version (statistics) {
                        DHT.info6.nodes_recv++;
                        if (is_really_blacklisted(wm.nodes6[20 .. 38]))
                            DHT.info6.blacklisted_nodes_recv++;
                    }
                    new_node(DHTId(wm.nodes6[0 .. 20]), wm.nodes6[20 .. 38], DHTNode.Reliability.dubious);
                    wm.nodes6 = wm.nodes6[38 .. $];
                }
                break;
            case "gp":
                Search* s = find_search(pinfo, thistid);
                if (s is null) {
                    fLog.warning("  Response to unknown search: ", wm.tid);
                    return;
                }

                if (search_step1(pinfo, s, wm.id, wm.token, from))
                    search_step2(pinfo, s, is_v6 ? wm.nodes6 : wm.nodes,
                        is_v6 ? wm.values6 : wm.values);
		// Normal, non-boot searches are always done in both networks.
		// If a multi-protocol client answers, the response can also contain 
		// nodes for the other network.	A boot search is network-specific.
                if (want == DHTProtocol.want46 && !s.is_boot_search) {
                    auto opinfo = other_pinfo(pinfo);
                    assert(opinfo !is null);
                    auto os = find_search(opinfo, thistid);
                    if (os is null) {
                        fLog.warning("  No twin search in other network: ", wm.tid);
                        break;
                    }
                    if (is_v6) {
                        if (wm.nodes.length > 0 || wm.values.length > 0)
                            search_step2(opinfo, os, wm.nodes, wm.values, 0);
                    } else {
                        if (wm.nodes6.length > 0 || wm.values6.length > 0)
                            search_step2(opinfo, os, wm.nodes6, wm.values6, 0);
                    }
                }
                break;
            case "ap":
                thistid.tcode = "gp";
                Search* s = find_search(pinfo, thistid);
                if (s is null) {
                    fLog.warning("  Response to unknown announce_peer: ", wm.tid);
                    return;
                }
                auto sn = (wm.id in s.snodes_seen);
                if (sn is null) {
               	    // This Sybil behaviour results in immediate blacklisting.
                    version (warnBlacklist)
                        fLog.warning("Node ", wm.id,
                            " replied with correct TID ", s.tid,
                            ", but is not in search. Foul play, blacklisting.");
                    blacklist(from,"AP injection");
                    return;
                }
                (*sn).status = SearchNode.Status.acked;
                break;
            default:
                fLog.trace("Non-implemented reply type: ", thistid);
            }
            break;
        case DHTMessageType.ping:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.info("Ping!");
            fLog.info("  Sending Pong");
            DHTNode.send_pong(pinfo, from, wm.tid);
            break;
        case DHTMessageType.get_peers:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.info("Get Peers!");
            DHTNode.send_nodes_peers(pinfo, from, wm.tid, wm.target, wm.want,
                make_token(from, wm.info_hash), find_storage(pinfo, wm.info_hash));
            break;
        case DHTMessageType.find_node:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.info("Find node!");
            fLog.info("  Sending closest nodes (" ~ to!string(wm.want) ~ ")");
            DHTNode.send_closest_nodes(pinfo, from, wm.tid, wm.target, wm.want);
            break;
        case DHTMessageType.announce_peer:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.info("Announce Peer!");
            if ((wm.token != make_token(from, wm.info_hash, false))
                    && (wm.token != make_token(from, wm.info_hash, true))) {
                fLog.warning("Wrong token:\n", make_token(from, wm.info_hash,
                    false), " expected\n", wm.token, " received");
                return;
            }
            storage_store(pinfo, wm.info_hash, from, wm.port,wm.id);
            fLog.info("Sending peer announced");
            DHTNode.send_peer_announced(pinfo, from, wm.tid);
            break;
        default:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.trace("Non-implemented message type: ", wm.message);
        }
	
	// Perform check of our own IP
	if(wm.own_ip.length > 0)
	    ip_check(pinfo,wm.own_ip);

    }

    protected bool parse_message(ubyte[] buf) {
	version(protocol_trace)
	    try {
	        fLog.info("Incoming:\n",to_ascii(buf,true));
	        fLog.info(bencode2ascii(buf));
            } catch (Exception e) 
                fLog.warning("Parse exception caught: ", e);

        // Prep	    
        wm = MessageWM.init; // Reset WM
        buf ~= 0; // ensure terminating \0
        ubyte[][] all_values; // values and values 6
        ubyte[][] all_want; // n4/n6 in want flags
        ubyte[] id;
        ubyte[] nodes, nodes6;
	
	const DHTMessageType[string] MTypeMap = [
	    "ping"          : DHTMessageType.ping,
	    "find_node"     : DHTMessageType.find_node,
	    "get_peers"     : DHTMessageType.get_peers,
	    "announce_peer" : DHTMessageType.announce_peer
	];
	
        alias FieldMapCallback = void delegate(ubyte[],ubyte[][],int);
        const FieldMapCallback[string] FieldMap = [
	    "info_hash" : (s,sl,i){ if(s.length == 20) wm.info_hash = DHTId(s);},
	    "port"      : (s,sl,i){ wm.port    = to!ushort(i);},
	    "target"    : (s,sl,i){ if(s.length == 20) wm.target = DHTId(s);},
	    "token"     : (s,sl,i){ wm.token   = s;},
	    "nodes"     : (s,sl,i){ nodes      = s;},
	    "nodes6"    : (s,sl,i){ nodes6     = s;},
	    "values"    : (s,sl,i){ all_values = sl;},
	    "want"      : (s,sl,i){ all_want   = sl;},
	    "e"         : (s,sl,i){ wm.message = DHTMessageType.error;},
	    "q"         : (s,sl,i){ if(cast(string) s in MTypeMap) 
	                                wm.message = MTypeMap[cast(string) s];  
				    else
					throw new Exception("Unknown message type: " ~ cast(string) s);
				  },
	    "t"         : (s,sl,i){ wm.tid = s; },
	    "y"         : (s,sl,i){ if(s=="r".representation) wm.message = DHTMessageType.reply ; },
	    "id"        : (s,sl,i){ id = s; },
	    "v"         : (s,sl,i){}, // ignore version
	    "ip"        : (s,sl,i){ wm.own_ip = s; }, 
	    "p"         : (s,sl,i){ }, // ignore p (port)
	];
	
	uint cur = 0;

	void parse_token(string id, ubyte[] s, ubyte[][] sl = null, int i = 0){
	    if(id in FieldMap)
	        FieldMap[id](s,sl,i);
	    else
	        fLog.trace("Ignoring unknown item \"" ~ id ~ "\"");
	}

        ubyte[] parse_bencode_string(){
            if(!isDigit(to!char(buf[cur])))
                throw new Exception("broken message - string expected, but got: " ~ to_ascii(buf[cur .. $],true));
        
            uint end=cur;
            while(end < buf.length && isDigit(to!char(buf[end])))
                end++;
        
            if(end >= buf.length || buf[end] != ':')
                throw new Exception("broken message - string");
        	
            uint len = to!uint(cast(string) buf[cur .. end]);
            
            if(end + len > buf.length)
                throw new Exception("broken message - EOM in string");
        	
            cur = end + len + 1;	
        	
            return buf[(end+1) .. cur];
        }
	
	void parse_bencode(string key_path = ""){
            switch(buf[cur]){
        	case 'd': // Dictionary: string-value pairs
        	    cur++;
        	    while(cur < buf.length && buf[cur] != 'e'){
        		string key = cast(string) parse_bencode_string();
			if(key_path.length > 0)
        		    parse_bencode(key);
			else
        		    parse_bencode(key);
        	    }
        	    cur++;
        	    break;
        	case 'l': // List - always assume it's a string list
        	    cur++;
        	    auto list = appender!(ubyte[][])();
		    while(cur < buf.length && buf[cur] != 'e')
        		list ~= parse_bencode_string();
        	    cur++;
		    parse_token(key_path,null,list.data);
        	    break;
        	case 'i': // Integer
        	    cur++;
                    uint end = cur;
        	    if(end >= buf.length)
        	        throw new Exception("broken message: unexpected end in integer field");
		    else if(isDigit(buf[end]) || buf[end] == '-')
        	        end++;
        	    else 
        	        throw new Exception("broken message: invalid character in integer field");
        	    
        	    while(end < buf.length && buf[end]!='e'){
        	        if(isDigit(buf[end]))
        	            end++;
        	        else 
        	            throw new Exception("broken message");
        	    }
		    if(end == buf.length)
        	        throw new Exception("broken message: unexpected end in integer field");
		    
                    parse_token(key_path,null,null,to!int(cast(string) buf[cur .. end]));
        	    cur = end + 1;
        	    break;
        	case '0': .. case '9': // String    
                    parse_token(key_path,parse_bencode_string);
        	    break;
        	default: throw new Exception("broken message: \"" ~ to_ascii(buf[cur .. $]) ~ "\"");
            }	    
        }

	

        try{
	    // Apparently sometimes a junk byte is added to the end of the buffer - 
	    // silently ignore it.
            while(cur < buf.length-2 && buf[cur] != '\0')
                parse_bencode();

            // Postprocess captured fields
            if (id.length != 20) {
                fLog.warning("broken message: ID missing or broken");
                return false;
            }
            wm.id = DHTId(id);

            foreach (v; all_values) {
                if (v.length == 6 && !is_martian(v, false) && !is_blacklisted(v))
                    wm.values ~= v;
                else if (v.length == 18 && !is_martian(v, true) && !is_blacklisted(v))
                    wm.values6 ~= v;
            }
            foreach (v; all_want) {
                if (v == ['n', '4']) // "n4"
                    wm.want |= DHTProtocol.want4;
                else if (v == ['n', '6']) // "n6"
                    wm.want |= DHTProtocol.want6;
            }

            // Make sure incoming node data is clean
            if ((nodes.length % 26 != 0) || (nodes6.length % 38 != 0))
                return false;

            auto nblob = appender!(ubyte[])();
            while (nodes.length > 0) {
                if (!is_junk(&DHT.info, DHTId(nodes[0 .. 20]), nodes[20 .. 26], false, false, "in get_peers/find_node reply"))
                    nblob ~= nodes[0 .. 26];
                nodes = nodes[26 .. $];
            }
            wm.nodes = nblob.data.dup;

            auto n6blob = appender!(ubyte[])();
            while (nodes6.length > 0) {
                if (!is_junk(&DHT.info6, DHTId(nodes6[0 .. 20]), nodes6[20 .. 38], true, false, "in get_peers/find_node reply"))
                    n6blob ~= nodes6[0 .. 38];
                nodes6 = nodes6[38 .. $];
            }
            wm.nodes6 = n6blob.data.dup;


	    // Some boot servers 
	    
        }	    
        // Something went wrong
        catch (Exception e) {
            fLog.warning("Exception caught: ", e);
            return false;
        }
        return true;
    }

    protected bool parse_message_old(ubyte[] buf) {
	    version(protocol_trace)
			fLog.info("Incoming:\n",to_ascii(buf,true),"\n",bencode2ascii(buf));
			
        bool find_static_length_field(in ubyte[] haystack, in ubyte[] needle,
            out ubyte[] whereto, in ushort len) {
            const(ubyte)[] found = find(haystack, needle);

            if (found.length == 0)
                return false;

            auto nlen = needle.length;

            if ((found.length <= len + nlen))
                throw new Exception(
                    "broken message looking for '" ~ to_ascii(needle) ~ "' buf=\n" ~ to_ascii(haystack));

            whereto = found[nlen .. (nlen + len)].dup;
            return true;
        }

        bool find_flex_length_field(in ubyte[] haystack, in ubyte[] needle, out ubyte[] whereto) {
            const(ubyte)[] found = find(haystack, needle);

            if (found.length == 0)
                return false;

            auto nlen = needle.length;

            if (found.length <= nlen + 1) // at least 1 char + \0
                throw new Exception("broken message");

            char* ptr = cast(char*)&found[nlen];
            char* endptr;
            //long fieldlen;
            uint fieldlen;
            fieldlen = cast(uint)(strtol(ptr, &endptr, 10));
            if (!endptr)
                throw new Exception("broken message");

            auto lenlen = endptr - ptr;
            if (nlen + lenlen + fieldlen > (found.length - 2))
                throw new Exception("broken message");

            //whereto = found[(nlen + lenlen + 1) .. (nlen + lenlen + fieldlen + 1)].dup;
            whereto = found[(nlen + lenlen + 1) .. (nlen + lenlen + fieldlen + 1)].dup;
            return true;
        }

        bool find_stringlist_field(in ubyte[] haystack, in ubyte[] needle, out ubyte[][] whereto) {
            const(ubyte)[] found = find(haystack, needle);

            if (found.length == 0)
                return false;

            auto nlen = needle.length;

            if (found.length <= nlen + 1) // at least 1 char + \0
                throw new Exception("broken message");

            found = found[nlen .. found.length];

            while (1) {
                char* endptr;
                uint fieldlen;
                fieldlen = cast(uint) strtol(cast(char*) found.ptr, &endptr, 10);

                if (endptr && *endptr == ':' && fieldlen > 0) {
                    //auto lenlen = endptr - cast(char*) found.ptr;
                    uint lenlen = cast(uint)(endptr - cast(char*) found.ptr);
                    if (lenlen + fieldlen > (found.length - 2))
                        throw new Exception("broken message");

                    whereto ~= found[(lenlen + 1) .. (lenlen + fieldlen + 1)].dup;
                    found = found[(lenlen + fieldlen + 1) .. found.length];
                } else
                    break;
            }
            return true;
        }

        bool find_int_field(INTT)(in ubyte[] haystack, in ubyte[] needle, out INTT whereto) {
            const(ubyte)[] found = find(haystack, needle);

            if (found.length == 0)
                return false;

            auto nlen = needle.length;

            if (found.length <= nlen + 1) // at least 1 char + \0
                throw new Exception("broken message");

            char* ptr = cast(char*)&found[nlen];
            char* endptr;
            long l;
            l = strtol(ptr, &endptr, 10);
            if (endptr) {
                whereto = to!INTT(l);
                return true;
            }

            throw new Exception("broken message");
        }

        // our search patterns
        const static ubyte[]//data
        tid_search = "1:t".representation, id_search = "2:id20:".representation,
            info_hash_search = "9:info_hash20:".representation,
            port_search = "porti".representation,
            target_search = "6:target20:".representation,
            token_search = "5:token".representation,
            nodes_search = "5:nodes".representation,
            nodes6_search = "6:nodes6".representation,
            values_search = "6:valuesl".representation,
            want_search = "4:wantl".representation,
            // message types
            reply_search = "1:y1:r".representation,
            error_search = "1:y1:e".representation,
            mandatory_search = "1:y1:q".representation,
            ping_search = "1:q4:ping".representation,
            find_node_search = "1:q9:find_node".representation,
            get_peers_search = "1:q9:get_peers".representation,
            announce_peer_search = "1:q13:announce_peer".representation;

        wm = MessageWM.init; // Reset WM
        buf ~= 0; // ensure terminating \0
        ubyte[][] all_values; // values and values 6
        ubyte[][] all_want; // n4/n6 in want flags
        ubyte[] id, target, info_hash;
        ubyte[] nodes, nodes6;

        try { // collect WM data
            find_flex_length_field(buf, tid_search, wm.tid);
            find_static_length_field(buf, id_search, id, 20);
            find_static_length_field(buf, info_hash_search, info_hash, 20);
            find_int_field(buf, port_search, wm.port);
            find_static_length_field(buf, target_search, target, 20);
            find_flex_length_field(buf, token_search, wm.token);
            find_flex_length_field(buf, nodes_search, nodes);
            find_flex_length_field(buf, nodes6_search, nodes6);
            find_stringlist_field(buf, values_search, all_values);
            find_stringlist_field(buf, want_search, all_want);

            // Message types
            if (find(buf, reply_search).length > 0)
                wm.message = DHTMessageType.reply;
            if (find(buf, error_search).length > 0)
                wm.message = DHTMessageType.error;
            if (find(buf, ping_search).length > 0)
                wm.message = DHTMessageType.ping;
            if (find(buf, find_node_search).length > 0)
                wm.message = DHTMessageType.find_node;
            if (find(buf, get_peers_search).length > 0)
                wm.message = DHTMessageType.get_peers;
            if (find(buf, announce_peer_search).length > 0)
                wm.message = DHTMessageType.announce_peer;

            // Postprocess captured fields
            if (id.length != 20) {
                fLog.warning("broken message: ID missing or broken");
                return false;
            }
            wm.id = DHTId(id);

            foreach (v; all_values) {
                if (v.length == 6 && !is_martian(v, false) && !is_blacklisted(v))
                    wm.values ~= v;
                else if (v.length == 18 && !is_martian(v, true) && !is_blacklisted(v))
                    wm.values6 ~= v;
            }
            foreach (v; all_want) {
                if (v == ['n', '4']) // "n4"
                    wm.want |= DHTProtocol.want4;
                else if (v == ['n', '6']) // "n6"
                    wm.want |= DHTProtocol.want6;
            }

            if (info_hash.length == 20)
                wm.info_hash = DHTId(info_hash);

            if (target.length == 20)
                wm.target = DHTId(target);

            // Make sure incoming node data is clean
            if ((nodes.length % 26 != 0) || (nodes6.length % 38 != 0))
                return false;

            auto nblob = appender!(ubyte[])();
            while (nodes.length > 0) {
                if (!is_junk(&DHT.info, DHTId(nodes[0 .. 20]), nodes[20 .. 26], false, false, "in get_peers/find_node reply"))
                    nblob ~= nodes[0 .. 26];
                nodes = nodes[26 .. $];
            }
            wm.nodes = nblob.data.dup;

            auto n6blob = appender!(ubyte[])();
            while (nodes6.length > 0) {
                if (!is_junk(&DHT.info6, DHTId(nodes6[0 .. 20]), nodes6[20 .. 38], true, false, "in get_peers/find_node reply"))
                    n6blob ~= nodes6[0 .. 38];
                nodes6 = nodes6[38 .. $];
            }
            wm.nodes6 = n6blob.data.dup;

        }
        catch (Exception e) {
            fLog.warning("Exception caught: ", e);
            return false;
        }
        return true;
    }
    
    
    
    protected static DHTBucket find_bucket(DHTInfo* pinfo, DHTId id) {
        DHTBucket b = pinfo.buckets.first;
        while (1) {
            if (b.next is null)
                return b;
            if (id < b.next.lower)
                return b;
            b = b.next;
        }
    }

    // Handles an incoming node (Sender of a message or get_peers/find_node data)
    // 
    protected void new_node(DHTInfo* pinfo, DHTId id, Address from, DHTNode.Reliability rel) {
        DHTBucket bucket;
        DHTNode this_node;

        fLog.trace("id=", id, " addr=", from, " rel=", rel);

        if (id in pinfo.bucket_nodes) {
            this_node = pinfo.bucket_nodes[id];

            if (rel >= DHTNode.Reliability.sent) {
                this_node.last_seen = now;
            }

            if (rel == DHTNode.Reliability.replied) {
                this_node.last_replied = now;
                this_node.last_pinged = 0;
                this_node.ping_count = 0;
                this_node.bucket.age = now;
            }
            fLog.trace("is known");
            return;
        }

        bucket = find_bucket(pinfo, id);
        bool mybucket = (bucket is pinfo.my_bucket);
        bool id_matches_ip;
	bool id_match_checked = false;
	
	// see if we may insert this node at all
	if(bucket.locked_for_good_ids){
	    id_matches_ip = is_id_by_ip(id,to_blob(from));
	    if(!id_matches_ip){
	        fLog.trace("Won't store bad node in locked bucket");
		return;
	    } 
	    id_match_checked = true;
	}
	
        /* Try to replace a bad node, moving backwards. Oldest, most reliable nodes stay at head of list */
        auto n = bucket.nodes.last;
        while (n !is null) {
            if (n.ping_count >= globals.bucket_max_ping_count
                    && n.last_pinged < now - globals.bucket_max_ping_time) {
                auto newn = new DHTNode(id, from, bucket,id_match_checked,id_matches_ip);

                pinfo.bucket_nodes.remove(n.id);
                bucket.nodes.remove(n);
                newn.last_seen = rel == DHTNode.Reliability.dubious ? 0 : now;
                newn.last_replied = rel == DHTNode.Reliability.replied ? now : 0;
                bucket.nodes.addBack(newn);
                pinfo.bucket_nodes[id] = newn;
                fLog.trace("replaced bad");
                return;
            }
            n = n.prev;
        }

        /* Bucket is full - ping dubious node, moving backwards */
        if (bucket.nodes.num >= globals.bucket_size) {
            bool dubious = false;
            n = bucket.nodes.last;
            while (n !is null) {
                if (!n.is_good) {
                    dubious = true;
                    if (n.last_pinged < now - globals.bucket_max_ping_time) {
                        fLog.info("Sending ping to dubious node.");
                        n.send_ping();
                        break;
                    }
                }
                n = n.prev;
            }

            bool split = false;
            if (mybucket && pinfo.buckets.num < globals.bucket_max_num) {
                if (!dubious || pinfo.buckets.num == 1)
                    split = true;
            }
            if (split) {
                bucket.split();
                new_node(pinfo, id, from, rel);
                return;
            }

	    /* If this bucket is not yet locked and this is a matching node,
	       try pushing out non-matching nodes. Replace the youngest one. */
	    
	    if(!bucket.locked_for_good_ids && rel != DHTNode.Reliability.dubious){
                if(!id_match_checked){
		    id_matches_ip = is_id_by_ip(id,to_blob(from));
	            id_match_checked = true;	        
	        }
		
		if(id_matches_ip)
		    for(n = bucket.nodes.last; n !is null; n = n.prev)
		        if(!n.id_matches_ip){
                            auto newn = new DHTNode(id, from, bucket,id_match_checked,id_matches_ip);
                            
                            pinfo.bucket_nodes.remove(n.id);
                            bucket.nodes.remove(n);
                            newn.last_seen = rel == DHTNode.Reliability.dubious ? 0 : now;
                            newn.last_replied = rel == DHTNode.Reliability.replied ? now : 0;
                            bucket.nodes.addBack(newn);
                            pinfo.bucket_nodes[id] = newn;
                            fLog.trace("replaced non-matching");
                            return;
		        }
	    
	    }
	    
            /* No space - cache away */
            if (rel != DHTNode.Reliability.dubious) {
                bucket.store_cache(from);
                fLog.trace("Bucket full - caching");
            } else
                fLog.trace("Bucket full - no action");
            return;
        }

        /* Create new node */
        this_node = new DHTNode(id, from, bucket,id_match_checked,id_matches_ip);
        this_node.last_seen = rel == DHTNode.Reliability.dubious ? 0 : now;
        this_node.last_replied = rel == DHTNode.Reliability.replied ? now : 0;
        pinfo.bucket_nodes[id] = this_node;
        bucket.nodes.addBack(this_node);
        fLog.trace("Adding as new node");
    }

    // Version for incoming addresses (get_peers, find_node)
    protected void new_node(DHTId id, ubyte[] from, DHTNode.Reliability rel) {
        new_node(from.length == 18 ? &info6 : &info, id, to_address(from), rel);
    }

    // Neighbourhood discovery: Multi-protocol entry point
    private void neighbourhood_maintenance() {
        if (want & DHTProtocol.want4)
            neighbourhood_maintenance(&info);
        if (want & DHTProtocol.want6)
            neighbourhood_maintenance(&info6);

        //  Slow down after 10 minutes
        if (now - globals.scheduler_neighbourhood_maintenance_late_when > starttime)
            scheduler.reschedule_later(ScheduleType.neighbourhood_maintenance,
                globals.scheduler_neighbourhood_maintenance_late);
    }

    // Neighbourhood discovery: Ask a random node in our bucket about 
    // nodes close to our ID, filling the bucket and eventually 
    // splitting it.
    private void neighbourhood_maintenance(DHTInfo* pinfo) {
        DHTBucket mb = pinfo.my_bucket;
        DHTBucket wb = mb;
        DHTId lookfor = pinfo.myid;
        lookfor.id[19] ^= 0xff; // 152 bit match to own ID    

        if (wb.next && (wb.nodes.num == 0 || uniform(0, 8) == 0))
            wb = wb.next;

        if (mb.prev && (wb.nodes.num == 0 || uniform(0, 8) == 0))
            wb = mb.prev;

        if (wb.nodes.num == 0)
            return;

        DHTNode n = wb.random_node();

        fLog.info(
            "Sending find_node for " ~ (pinfo.is_v6 ? "IPv6" : "IPv4") ~ " neighbourhood maintenance.");
        n.send_find_node(DHTtid("fn", 0), lookfor, DHT.want);
        n.pinged();
    }

    // Keeping the buckets fresh: Multi-protocol entry point
    private void bucket_maintenance() {
        if (want & DHTProtocol.want4)
            bucket_maintenance(&info);
        if (want & DHTProtocol.want6)
            bucket_maintenance(&info6);
    }

    // Keeping the buckets fresh: Every bucket which hasn't see node activity
    // for a certain period will get a random node queried for a random ID
    // within the bucket.
    private void bucket_maintenance(DHTInfo* pinfo) {
        DHTBucket mb = pinfo.buckets.first;

        while (mb) {
            if (mb.age < now - globals.bucket_max_age) {
                DHTBucket wb = mb;
                DHTId lookfor = mb.random;

                if (wb.next && (wb.nodes.num == 0 || uniform(0, 8) == 0))
                    wb = wb.next;

                if (mb.prev && (wb.nodes.num == 0 || uniform(0, 8) == 0))
                    wb = mb.prev;

                if (wb.nodes.num == 0) { // Nothing to do!
                    mb = mb.next;
                    continue;
                }

                DHTNode n = wb.random_node();
                DHTProtocol want = DHTProtocol.nowant;

                // for dual-stack instances, ask for nodes for sister bucket,
                // but rarely do so.
                if (DHT.want == DHTProtocol.want46 && uniform(0, 37) == 0)
                    want = DHTProtocol.want46;

                fLog.info(
                    "Sending find_node for " ~ (pinfo.is_v6 ? "IPv6" : "IPv4") ~ " bucket maintenance.");
                n.send_find_node(DHTtid("fn", 0), lookfor,
                    DHT.want == DHTProtocol.want46 ? DHTProtocol.want46 : DHTProtocol.nowant);
                n.pinged();
                /* In order to avoid sending queries back-to-back,
                    give up for now and reschedule us soon. */
                return;
            }
            mb = mb.next;
        }
        fLog.trace((pinfo.is_v6 ? "IPv6" : "IPv4") ~ " bucket maintenance found no stale buckets.");
    }

    // Weed out dead nodes in buckets:  Multi-protocol entry point
    private void expire_buckets() {
        fLog.trace("Expiring stale buckets");
        if (want & DHTProtocol.want4)
            expire_buckets(&info);
        if (want & DHTProtocol.want6)
            expire_buckets(&info6);
    }

    // Weed out dead nodes in buckets: Remove dead nodes and try to insert each node
    // from the cache instead.
    protected void expire_buckets(DHTInfo* pinfo) {
        uint removed_nodes = 0;
	DHTNode nextnode;
	for (auto bucket = pinfo.buckets.first; bucket !is null; bucket = bucket.next)
            for (auto node = bucket.nodes.first; node !is null; node = nextnode){
	        nextnode = node.next;
                if (node.ping_count > globals.bucket_max_ping_count) {
                    bucket.nodes.remove(node);
                    bucket.send_cached_ping();
                    pinfo.bucket_nodes.remove(node.id);
		    ++removed_nodes;
                }
	    }

        if(removed_nodes > 0)	
	    fLog.info("Expired ",removed_nodes," ",pinfo.is_v6 ? "IPv6" : "IPv4", " nodes");	
    }
    // Remove old searches:  Multi-protocol entry point
    private void expire_searches() {
        fLog.trace("Expiring finished searches");
        if (want & DHTProtocol.want4)
            expire_searches(&info);
        if (want & DHTProtocol.want6)
            expire_searches(&info6);
    }

    // Remove old searches: Searches which are done and are older than
    // our defined threshold can be removed.
    private void expire_searches(DHTInfo* pinfo) {
        auto as = appender!(DHTtid[])();
        foreach (sk, s; pinfo.searches)
            if (s.status == Search.Status.done && s.age < now - globals.search_expiry)
                as ~= sk;

        foreach (sk; as.data)
            pinfo.searches.remove(sk);
    }

    // Check if lock bucket:  Multi-protocol entry point
    private void check_bucket_lock() {
        fLog.trace("Checking buckets for lockdown");
        if (want & DHTProtocol.want4)
            check_bucket_lock(&info);
        if (want & DHTProtocol.want6)
            check_bucket_lock(&info6);
    }
    // Check each bucket if it has enough nodes where ID matches IP;
    // If so, lockdown the bucket
    private void check_bucket_lock(DHTInfo* pinfo) {
	for (auto bucket = pinfo.buckets.first; bucket !is null; bucket = bucket.next){
	    // If bucket is deserted due to locking, unlock it.
	    if(bucket.locked_for_good_ids){
	        if(bucket.nodes.num <= globals.bucket_unlock_nodes){
		    fLog.trace("Unlocking ",pinfo.is_v6 ? "IPv6" : "IPv4"," bucket ",bucket.lower.toString(false)," nodes=",bucket.nodes.num);
		    bucket.locked_for_good_ids = false;
                }		    
	        continue;
	    }

            if(bucket is pinfo.my_bucket && globals.bucket_max_num>1) 
	        continue; // never lock own bucket - splitting slows down or is prohibited
		
	    int num_good_id_nodes = 0;
		
            for (auto node = bucket.nodes.first; node !is null; node = node.next)
	        if(node.id_matches_ip && node.is_good)
		    num_good_id_nodes++;
	
            if(num_good_id_nodes < globals.bucket_lock_good_id_nodes)
                continue; // not yet enough	    
		
	    // remove all nodes where ID does not match IP	
	    fLog.trace("Locking down ",pinfo.is_v6 ? "IPv6" : "IPv4"," bucket ",bucket.lower.toString(false));
	    DHTNode next_node;
            for (auto node = bucket.nodes.first; node !is null; node = next_node){
	        next_node = node.next;
	    
	        if(!node.id_matches_ip){
		    bucket.nodes.remove(node);
		    pinfo.bucket_nodes.remove(node.id);
		}
	    }
	    // Empty the cache - there may be more good nodes.
	    bucket.send_cached_ping(DHT.globals.bucket_cache_size); 
	    
	    bucket.locked_for_good_ids = true;
        }
    }


    
    
    // Store an announced address. Addresses with the youngest announce time are 
    // at the back of the storage (simplifies cleanup)
    private void storage_store(DHTInfo* pinfo, DHTId info_hash, Address from, ushort port, DHTId sender_id) {
        if (port == 0)
            return; // silently ignore junk port

        AddressBlob blob = to_addressblob(from);

	
        if (pinfo.is_v6)
            blob.port6 = htons(port);
        else
            blob.port4 = htons(port);

        if(!is_id_by_ip(sender_id, pinfo.is_v6 ? blob.ablob6 : blob.ablob4)){
            fLog.trace("Announcing ID ", sender_id," does not match IP, silently ignoring.");
	    return;
	}
	
	    
	    
	    
        fLog.trace(from, " announces ", info_hash, " at port ", port);

        idStorage* ids;
        if (info_hash in pinfo.storage)
            ids = pinfo.storage[info_hash];
        else {
            ids = new idStorage;
            pinfo.storage[info_hash] = ids;
        }

        idAddressStorage* ias;
        if (blob in ids.addresshash) {
            ias = ids.addresshash[blob];
            ids.addresses.remove(ias);
            if (ids.walker is ias)
                ids.walker = ias.prev;
        } else {
            ias = new idAddressStorage;
            ias.address = blob;
            ids.addresshash[blob] = ias;
        }
        ias.age = DHT.now;
        ids.addresses.addBack(ias);
    }

    // Get all addresses stored for a given infohash.
    // The "walker" steps through the list, effectively spreading the load across 
    // all addresses of a large storage.
    private ubyte[] find_storage(DHTInfo* pinfo, DHTId info_hash,
        int maxnum = globals.storage_return_results) {
        if (info_hash !in pinfo.storage)
            return [];

        idStorage* ids = pinfo.storage[info_hash];

        if (maxnum > ids.addresses.num)
            maxnum = ids.addresses.num;

        auto block = appender!(ubyte[])();
        while (maxnum-- > 0) {
            if (ids.walker is null)
                ids.walker = ids.addresses.last;
            if (pinfo.is_v6) {
                if (!is_blacklisted(ids.walker.address.blob6))
                    block ~= ids.walker.address.blob6[];
            } else {
                if (!is_blacklisted(ids.walker.address.blob4))
                    block ~= ids.walker.address.blob4[];
            }
            ids.walker = ids.walker.prev;
        }
        return block.data;
    }

    // Remove old storage entries:  Multi-protocol entry point
    private void expire_storage() {
        fLog.trace("Expiring stale storage");
        if (want & DHTProtocol.want4)
            expire_storage(&info);
        if (want & DHTProtocol.want6)
            expire_storage(&info6);
    }

    // Remove old storage entries:  As all storage entries for an infohash
    // are sorted by announce date, we have only a fraction of entries to check.
    private void expire_storage(DHTInfo* pinfo) {
        auto empty_storage_keys = appender!(DHTId[])();
        time_t threshold = DHT.now - globals.storage_expiry;

        foreach (id, idstore; pinfo.storage) {
            while (idstore.addresses.num > 0) {
                auto head = idstore.addresses.first;

                if (head.age > threshold)
                    break; // the rest is younger
                if (idstore.walker is head)
                    idstore.walker = null;
                idstore.addresses.remove(head);
		idstore.addresshash.remove(head.address);
            }

            if (idstore.addresses.num == 0)
                empty_storage_keys ~= id;
        }

        foreach (emptyk; empty_storage_keys.data)
            pinfo.storage.remove(emptyk);
    }

    // Remove old storage seen addresses:  remove entries we haven't seen
    // for a while. Also clean up blacklist.
    private void expire_seen_addresses() {
        auto delkeys = appender!(const(ubyte)[][])();
        foreach (k, v; seen_addresses)
            if (v.last_seen <= now - globals.junk_seen_addresses_max_age)
                delkeys ~= k;

        foreach (k; delkeys.data)
            seen_addresses.remove(k);

        delkeys.clear();
        foreach (k, v; sybil_watch_addresses)
            if (v.last_seen <= now - globals.junk_seen_addresses_max_age)
                delkeys ~= k;

        foreach (k; delkeys.data)
            sybil_watch_addresses.remove(k);

        delkeys.clear();
        foreach (k, v; blacklisted)
            if (v.last_seen <= now - globals.junk_blacklist_addresses_max_age)
                delkeys ~= k;

        foreach (k; delkeys.data)
            blacklisted.remove(k);

    }

    // Make sure long-lived central hashes don't deteriorate
    private void rehash() {
        fLog.info("Rehash started");
        seen_addresses.rehash();
        blacklisted.rehash();
        rehash(&info);
        rehash(&info6);
        fLog.info("Rehash finished");
    }

    private void rehash(DHTInfo* pinfo) {
        pinfo.bucket_nodes.rehash();
        pinfo.storage.rehash();
    }

    // Start a new search:  Multi-protocol entry point
    // The TID is identical for both protocols, so we
    // can share multi-protocol replies (nodes)
    // across both protocol DHTs.
    public void new_search(DHTId info_hash, ushort port = 0) {
        fLog.info("New search for ", info_hash);
        DHTtid tid = DHTtid("gp");
        if (DHT.want & DHTProtocol.want4)
            new_search(&info, info_hash, tid, port);
        if (DHT.want & DHTProtocol.want6)
            new_search(&info6, info_hash, tid, port);

    }

    // Start a new search:  Fill the initial search bucket with 
    // known nodes closest to the infohash. If possible, try to re-use
    // earlier search results.
    private void new_search(DHTInfo* pinfo, DHTId info_hash, DHTtid tid,
        ushort port = 0, bool boot_search = false) {
        ubyte[] closest_nodes = gather_closest_nodes(pinfo, info_hash,
            globals.search_bucket_size);
        if (closest_nodes.length == 0) {
            fLog.warning("Search for ", info_hash,
                " stalled - there are no good nodes in our " ~ (pinfo.is_v6 ? "IPv6" : "IPv4") ~ " buckets");
        }

        Search* s = new Search(info_hash, tid, port);
        // Check if we can recycle nodes of an old search.
        foreach (s_old; pinfo.searches.values)
            if (s_old.info_hash == info_hash)
                foreach (sn; s_old.snodes)
                    if (sn.status == SearchNode.Status.replied
                            || sn.status == SearchNode.Status.acked)
                        s.snodes ~= new SearchNode(s, sn.id, sn.address);

        pinfo.searches[tid] = s;
        s.is_boot_search = boot_search;

        search_step2(pinfo, s, closest_nodes, [], globals.search_parallel_queries);
    }

    // If a search has been started too early, try to revive it - typically a boot search.
    private void revive_search(DHTInfo* pinfo, Search* s) {
        ubyte[] closest_nodes = gather_closest_nodes(pinfo,
            s.info_hash, globals.search_bucket_size);
        if (closest_nodes.length == 0) {
            fLog.warning(pinfo.is_v6 ? "IPV6" : "IPV4", " revive for ",
                s.info_hash, " stalled - there are no good nodes in our buckets");
            return;
        } else
            s.age = now;
        fLog.trace(pinfo.is_v6 ? "IPV6" : "IPV4", " revive for ", s.info_hash, " successful");
        search_step2(pinfo, s, closest_nodes, [], globals.search_parallel_queries);
    }

    protected Search* find_search(DHTInfo* pinfo, DHTtid tid) {
        Search** s = (tid in pinfo.searches);
        return (s is null ? null : *s);
    }

    // Search step #1: mark replying node as replied and remove dead nodes
    protected bool search_step1(DHTInfo* pinfo, Search* s, DHTId from, ubyte[] token,
        Address a) {
        	
        if(a !is null){	// push_searches does not have a sender
            if (from in s.snodes_seen) {
                auto sn = s.snodes_seen[from];
                sn.status = SearchNode.Status.replied;
                sn.last_pinged = 0;
                sn.token = token.dup;
            } else {
                // This is not necessarily Sybil behaviour - it 
                // could also mean that the ID information we got about this node
                // has changed in the meantime (client restart w/ new ID).
                // We ignore these results.
                version (warnBlacklist)
                    fLog.warning("Node ", from, " replied with correct TID ",
                        s.tid, ", but is not in search.");
                return false;
            }
        }

        SearchNode*[] goodnodes;
        goodnodes.reserve(globals.search_bucket_size);
        foreach (n; s.snodes)
            if ((n.status < DHT.SearchNode.Status.pinged3)
                    || (n.last_pinged > DHT.now - globals.search_max_ping_time))
                goodnodes ~= n;
        s.snodes = goodnodes;
        s.responses++;
        return true;
    }

    // Search step #2: Add new results to search bucket, keeping the top n nodes
    protected void search_step2(DHTInfo* pinfo, Search* s, ubyte[] nodes_blob,
        ubyte[] results_blob, uint howmany = 1) {
        if (s.status == s.status.done && !s.is_boot_search)
            return;

        size_t nodes_blob_size = (pinfo.is_v6 ? 38 : 26);
        size_t results_blob_size = (pinfo.is_v6 ? 18 : 6);
        bool ongoing = false;

        if (s.status == s.status.searching || s.is_boot_search) {
            if (nodes_blob.length % nodes_blob_size != 0) {
                fLog.warning("Weird search blob size");
                return;
            }

            if (results_blob.length % results_blob_size != 0) {
                fLog.warning("Weird results blob size");
                return;
            }

            // Handle incoming nodes
            auto sa = appender(s.snodes);
            while (nodes_blob.length > 0) {
                DHTId id = DHTId(nodes_blob[0 .. 20]);
                Address a = to_address(nodes_blob[20 .. nodes_blob_size]);

                version (statistics) {
                    pinfo.nodes_recv++;
                    if (is_really_blacklisted(a))
                        pinfo.blacklisted_nodes_recv++;
                }

                s.numnodes++;
                if ((id != pinfo.myid) && (id !in s.snodes_seen)) {
                    new_node(pinfo, id, a, DHTNode.Reliability.dubious);
                    SearchNode* snode = new SearchNode(s, id, a);
                    sa ~= snode;

                    // Boot search: Split eagerly & trigger new search if 
                    // bucket contains own ID or is less than half full.
                    if (s.is_boot_search) {
                        DHTBucket b = find_bucket(pinfo, id);
                        while (b is pinfo.my_bucket && b.nodes.num >= globals.bucket_size && pinfo.buckets.num < globals.bucket_max_num) {
                            b.split();
                            b = find_bucket(pinfo, id);
                        }
                        if ((b is pinfo.my_bucket
                                || b.nodes.num < globals.search_boot_bucket_min)
                                && s.status != Search.Status.done) {
                            fLog.trace("Boot search ", s.tid, "/",pinfo.is_v6 ? "IPV6" : "IPV4", ": send_get_peers to ", id, " = ", a);
                            DHTNode.send_get_peers(pinfo, snode.address, s.tid,
                                s.info_hash, DHT.want);
                            snode.last_pinged = DHT.now;
                            snode.status++;
                            s.queries++;
                        }
                    }
                }
                nodes_blob = nodes_blob[nodes_blob_size .. $];
            }
            s.snodes = sa.data;

            // Handle incoming peer results
            auto ra = appender!(Address[])();
            while (results_blob.length > 0) {
                ubyte[] ablob = results_blob[0 .. results_blob_size];
                Address a = to_address(ablob);

                s.numpeers++;
                if (ablob !in s.found_peers) {
                    s.found_peers[ablob.idup] = a;
                    ra ~= a;
                }
                results_blob = results_blob[results_blob_size .. $];
            }

            if (ra.data.length > 0 && !s.is_boot_search)
                callback(
                    pinfo.is_v6 ? CallbackType.search_result_v6 : CallbackType.search_result_v4,
                    s.info_hash, ra.data);

            // restrict to TOP n
	    //enum sort_criteria = "(a.id_matches_p && a.status == SearchNode.Status.fresh) > (b.id_matches_p && b.status == SearchNode.Status.fresh)  a.distance < b.distance";
            alias sort_criteria =  (a,b){
	        auto ac = (a.id_matches_ip && a.status == SearchNode.Status.fresh);
	        auto bc = (b.id_matches_ip && b.status == SearchNode.Status.fresh);
		return((ac > bc) || ((ac == bc) && a.distance < b.distance));
	    };
		
	    if (s.snodes.length > globals.search_bucket_size) {
                s.snodes.topN!sort_criteria(globals.search_bucket_size);
                s.snodes = s.snodes[0 .. globals.search_bucket_size];
            }
            sort!sort_criteria(s.snodes);

            // Start with fresh nodes first - the chances of a node to answer
            // sinks rapidly with the 1st missed answer
            uint numpinged = 0;
            for (auto lookfor = SearchNode.Status.fresh; lookfor <= SearchNode.Status.pinged2;
                    lookfor++)
                for (int j = 0; j < s.snodes.length; j++) {
                    auto sn = s.snodes[j];

                    if ((sn.status == lookfor
                            || sn.last_pinged > DHT.now - globals.search_max_ping_time)
                            && j < globals.search_bucket_relevant)
                        ongoing = true;

                    if (sn.status != lookfor)
                        continue;

                    if (sn.last_pinged > now - globals.search_max_ping_time)
                        continue;

                    fLog.trace("Search ", s.tid, "/",
                        pinfo.is_v6 ? "IPV6" : "IPV4", ": send_get_peers to ",
                        sn.id, " = ", sn.address, " Status=", lookfor);
                    DHTNode.send_get_peers(pinfo, sn.address, s.tid, s.info_hash, DHT.want);
                    sn.last_pinged = DHT.now;
                    sn.status++;
                    s.queries++;

                    // If this is a regular bucket node, mark it as pinged.
                    auto bucketnode = (sn.id in pinfo.bucket_nodes);
                    if (bucketnode !is null)
                        bucketnode.pinged();

                    if (++numpinged >= howmany) {
                        return;
                    }
                }
        }

        // Check if search phase is over	
        if (!ongoing && s.snodes.length > 0) {
            if (s.port != 0 && s.status == s.Status.searching) { // enter announce phase
                s.tid.tcode = "ap";
                s.status = s.Status.announcing;
                s.status_since = now;

                foreach (sn; s.snodes)
                    if (sn.status == sn.Status.replied) {
                        DHTNode.send_announce_peer(pinfo, sn.address, s.tid,
                            s.info_hash, sn.token, s.port);
                        sn.status = sn.Status.pinged1;
                        sn.last_pinged = now;
                    } else
                        sn.status = sn.Status.dead;

                return; // Come back later.
            } else if (s.status == s.Status.announcing) {
                bool all_acked = true;
                foreach (sn; s.snodes)
                    if (sn.status != sn.Status.acked) {
                        all_acked = false;
                        if (sn.last_pinged <= now - globals.search_max_ping_time) {
                            DHTNode.send_announce_peer(pinfo, sn.address,
                                s.tid, s.info_hash, sn.token, s.port);
                            sn.status++;
                            sn.last_pinged = now;
                        }
                    }
                if (!all_acked)
                    return;
            }
            // This search is finished. Inform the host application.
            s.status = s.Status.done;
            s.status_since = now;
            fLog.info("Search for ", s.info_hash, " finished");
            if (!s.is_boot_search)
                callback(
                    pinfo.is_v6 ? CallbackType.search_finished_v6 : CallbackType.search_finished_v4,
                    s.info_hash, s.found_peers.values);
	    else  // Boot search: Set bucket age to "old" to start bucket maintenance 
	        for(auto bucket = pinfo.buckets.first; bucket !is null ; bucket = bucket.next)
		    bucket.age = 0;
		    
        }
    }

    // A boot search is a search for our own ID, targetted at 
    // filling buckets quickly.
    public void boot_search(DHTProtocol whichnet = DHT.want) {
        DHTId near_me;
        DHTtid tid = DHTtid("gp");

        if (whichnet & DHTProtocol.want4){
	    near_me = info.myid;
            near_me.id[19] ^= 0xff; // 152 bits identical
            new_search(&info, near_me, tid, 0, true);
	}
        if (whichnet & DHTProtocol.want6) {
	    near_me = info6.myid;
            near_me.id[19] ^= 0xff; // 152 bits identical
            new_search(&info6, near_me, tid, 0, true);
	}
    }

    // Move searches forward:  Multi-protocol entry point
    private void push_searches() {
        if (DHT.want & DHTProtocol.want4)
            push_searches(&info);
        if (DHT.want & DHTProtocol.want6)
            push_searches(&info6);
    }

    // Move searches forward: 
    private void push_searches(DHTInfo* pinfo) {
        foreach (s; pinfo.searches.values) {
            if (s.status == s.Status.done)
                continue;

            // Boot search: Check if we have achieved the desired number of buckets - if so, mark as finished.	
            if (s.is_boot_search && pinfo.buckets.num >= (pinfo.is_v6 ? 14 : 20)) {
                s.status = s.Status.done;
                s.status_since = now;

		// Make sure bucket maintenance will pick up the buckets
	        for(auto bucket = pinfo.buckets.first; bucket !is null ; bucket = bucket.next)
		    bucket.age = 0;
		    
                fLog.info("Boot search completed (", pinfo.is_v6 ? "IPV6" : "IPV4",
                    ")\n");
                continue;
            }

            if (s.snodes.length == 0)
                revive_search(pinfo, s);
            else {
                search_step1(pinfo, s, DHTId.zero, null, null); // only remove dead nodes
                search_step2(pinfo, s, [], [], globals.search_parallel_queries);
            }
        }
    }

    // Create MD5 token (128 bits)
    // 
    protected ubyte[] make_token(Address a, DHTId asks_for, bool use_old_secret = false) {
        static bool initialised = false;

        if (!initialised) {
            foreach (v; 0 .. 16)
                secret ~= uniform(0, 255) & 0xff;
            secret_old = secret;
            initialised = true;
        }

        ubyte[] s = (use_old_secret ? secret_old : secret);

        MD5 hash;
        hash.start();
        hash.put(s);
        hash.put(to_addressblob(a).blob6);
        hash.put(asks_for.id);
        return hash.finish().dup;
    }

    // This should not be called too often
    public void change_secret(ubyte[] new_secret) {
        secret_old = secret;
        secret = new_secret;
    }

    // Junk filter - all incoming addresses must pass this filter.
    protected bool is_junk(DHTInfo* pinfo, DHTId id, Address a, bool is_v6,
        bool blacklist_own_id, string bl_msg) {
        return is_junk(pinfo, id, to_blob(a), is_v6, blacklist_own_id, bl_msg);
    }

    // Junk filter - all incoming addresses must pass this filter.
    // In case we disable the blacklist, there should be still warnings and a blacklist entry,
    // but it has no effect.
    protected bool is_junk(DHTInfo* pinfo, DHTId id, ubyte[] ablob, bool is_v6,
        bool blacklist_own_id, string bl_msg) {

        // Search results may return our own ID.
        // This is still a junk result, but must not lead to blacklisting.
        if (id == pinfo.myid) {
            if (blacklist_own_id) {
                version (warnBlacklist)
                    fLog.warning("Own ID with address ",
                        to_address(ablob), ", blacklisting (", bl_msg, ")");
                blacklist(ablob,"Own ID");
                version (statistics)
                    pinfo.blacklisted_recv++;
            }
            return true;
        }

        // Honeypot check
        auto cb = id.common_bits(pinfo.myid);
        if (cb >= globals.junk_honeypot_bits) {
            version (warnBlacklist)
                fLog.warning("ID ", id, " address ", to_address(ablob),
                    " seems to be a honeypot (", cb, " bits), blacklisting (", bl_msg,
                    ")");
            blacklist(ablob,"Honeypot/" ~ to!string(cb));
            version (statistics)
                pinfo.blacklisted_recv++;
            version (disable_blacklisting)
                return is_martian(ablob, is_v6); // skip rest
            else
                return true;
        }

        // Sybil check resulted in fresh or refreshed blacklist entry? It's junk.
        if(is_sybil(ablob,id))
            return true;
        else if(is_blacklisted(ablob))
            return true;

        return is_martian(ablob, is_v6);
    }

    private bool is_sybil(ubyte[] ablob,DHTId id){
    	SeenAddress* sa = (ablob in seen_addresses);
    	
    	// Never seen this one? All is fine.
    	if(sa is null){
    	    seen_addresses[ablob.idup] = SeenAddress(id);
    	    return false;
    	}
    	
    	// ID matches? All is fine.
    	sa.last_seen = now;
    	if(sa.id == id)
    	    return false; 
    	
    	SybilWatchAddress* swa = (ablob in sybil_watch_addresses);
    	if(swa is null){
    	    sybil_watch_addresses[ablob.idup] = SybilWatchAddress(sa.id);
    	    swa = &sybil_watch_addresses[ablob];
        } else 
            swa.last_seen = now;
            
    	sa.id = id;
    	version(statistics) swa.hits++;
    	
    	size_t where = -1;
    	foreach(idx, other_id ; swa.seen_as)
    	    if(other_id == id){
    	    	where = idx;
    	    	break;
    	    }
    	
    	// It's there, no size change, move entry to list start, all is fine.
    	if(where != -1){
    	    if(where != 0)
                swa.seen_as = id ~ swa.seen_as[0 .. where] ~ swa.seen_as[(where+1) .. $];
            return false;
        }
        
        // Sybil list grows
        swa.seen_as = id ~ swa.seen_as;
        
        // Sybil list hasn't breached threshold yet, all is fine
        if(swa.seen_as.length <= globals.sybil_max_num_ids)
    	    return false;
    	    
    	// This address is now considered a Sybil 
    	swa.seen_as = swa.seen_as[0 .. globals.sybil_max_num_ids];
    	blacklist(ablob, "Multiple IDs");
    	return true;    
    }

    // store this address with blacklisted DHTId, effectively blacklisting it
    protected void blacklist(ubyte[] ablob, string why) {
        blacklist_store_and_mark(to_blacklistblob(ablob),why);
    }

    protected void blacklist(Address a, string why) {
        blacklist_store_and_mark(to_blacklistblob(a),why);
    }

    private void blacklist_store_and_mark(ubyte[] ablob, string why) {
        BlacklistAddress* ba = (ablob in blacklisted);

        if(ba !is null){
            ba.last_seen = now;
    	    version (statistics){
                ba.hits++; 
                auto k = (why in ba.why);
                if(k is null)
                    ba.why[why.idup] = 1;
                else
                    (*k) ++;
            }
	    return;
	}

	// Sybil attackers may use the same IPv4 address in a 6to4 or Teredo variant.
	// Block all three.
	ubyte[][] address_variants;
	
	if(DHT.want == DHTProtocol.want4) // IPv4 only has no variants
	    address_variants = [ ablob ];
	else if(ablob.length == 4){ // IPv4
	    ubyte[16] teredo = [0x20,0x01,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
	    ubyte[16] _6to4  = [0x20,0x02,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
	    
	    _6to4[2..6] = ablob;
	    for(auto i=0;i<4;i++)	   
	        teredo[i+12] = ablob[i] ^ 0xff; // invert bits for Teredo
	    
	    address_variants = [ ablob, teredo, _6to4 ];
        } else if(ablob.length == 16) { 
            if (ablob[0 .. 2] == [0x20, 0x02]){ // 6to4
	        ubyte[16] teredo = [0x20,0x01,0,0,0,0,0,0,0,0,0,0,0,0,0,0];

	        for(auto i=0;i<4;i++)	   
	            teredo[i+12] = ablob[i+2] ^ 0xff; // invert bits for Teredo

		// Don't create IPv4 entry if IPv6-only
                if(DHT.want == DHTProtocol.want46)
	            address_variants = [ ablob, teredo, ablob[2..6] ];
	        else
	            address_variants = [ ablob, teredo ];
	    } else if(ablob[0 .. 4] == [0x20, 0x01, 0, 0]){ // Teredo
	        ubyte[16] _6to4  = [0x20,0x02,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
	        ubyte[4] ipv4;

	        for(auto i=0;i<4;i++)	   
	            _6to4[2+i] = ipv4[i] = ablob[i+12] ^ 0xff; // invert bits for Teredo
		
		// Don't create IPv4 entry if IPv6-only
                if(DHT.want == DHTProtocol.want46)
	            address_variants = [ ablob, _6to4, ipv4 ];
	        else
	            address_variants = [ ablob, _6to4 ];
	    } else 
	        address_variants = [ ablob ]; // "real" IPv6 address
	} else
	    assert(0);

	
        foreach(avariant; address_variants ){
            blacklisted[avariant.idup] = BlacklistAddress(0);
            version(statistics) blacklisted[avariant].why[why.idup] = 0;
            
            version (disable_blacklisting)
                continue; // mark but don't do anything. 
	        
            // now the fun starts: We need to remove this address from EVERYTHING.
	    foreach(pinfo; [&info,&info6]){
                for (auto b = pinfo.buckets.first; b !is null; b = b.next)
                    for (auto n = b.nodes.first; n !is null; n = n.next)
                        if (to_blacklistblob(n.address) == avariant) {
                            pinfo.bucket_nodes.remove(n.id);
                            b.nodes.remove(n);
                        }
                
                foreach (s; pinfo.searches)
                    foreach (sn; s.snodes)
                        if (to_blacklistblob(sn.address) == avariant)
                            sn.status = SearchNode.Status.blacklisted;
            }
	}
	// the first entry in address_variants is the original address.
	// Only this one received a hit.
	version(statistics){ 
	    blacklisted[address_variants[0]].hits = 1; 
	    blacklisted[address_variants[0]].why[why] = 1;
	}
    }

    // If blacklisting is disabled, always return false, but track 
    // the number of hits, if statistics are desired.
    private static bool is_blacklisted(ubyte[] ablob) {
        switch (ablob.length) {
            case 6:
            	ablob = ablob[0..4];
            	break;
            case 18:
	        ablob = to_blacklistblob(ablob);
	        break;
            case 4:
            case 16:
                break;
            default:
                assert(0); // Yikes	    
        }
        auto be = (ablob in DHT.blacklisted);
        if (be is null)
            return false;

        version (disable_blacklisting)
            return false;
        else
            return true;
    }

    private static bool is_blacklisted(Address a) {
        return is_blacklisted(to_blacklistblob(a));
    }

    // "is_really_blacklisted" is for statistics only,
    // even if blacklisting is disabled.
    version (statistics) {
        protected static bool is_really_blacklisted(Address a) {
            return is_really_blacklisted(to_blacklistblob(a));
        }

        protected static bool is_really_blacklisted(ubyte[] ablob) {
            switch (ablob.length) {
                case 6:
                	ablob = ablob[0..4];
                	break;
                case 18:
	            ablob = to_blacklistblob(ablob);
	            break;
                case 4:
                case 16:
                    break;
                default:
                    assert(0); // Yikes	    
            }
            return ablob in DHT.blacklisted ? true : false;
        }
    }

    // Basic check for bad (i.e., local, zeroport, etc) addresses
    private bool is_martian(ubyte[] ablob, bool is_v6) {
        if (is_v6)
            return ablob[16 .. 18] == [0, 0] || // Port
                (ablob[0] == 0xFF)
                || (ablob[0] == 0xFE && (ablob[1] & 0xC0) == 0x80)
                || (ablob[0 .. 15] == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                && (ablob[15] == 0 || ablob[15] == 1)) || (ablob[0 .. 12] == [0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]);
        else
            return ablob[4 .. 6] == [0, 0] || // Port
                (ablob[0] == 0) || (ablob[0] == 127)
                || ((ablob[0] & 0xE0) == 0xE0);
    }

    private struct SeenAddress {
        DHTId id;
        time_t last_seen;
        this(DHTId nid) {
            id = nid;
            last_seen = DHT.now;
        }
    }

    private struct SybilWatchAddress {
        time_t last_seen;
        DHTId[] seen_as;
        version (statistics){
            uint hits = 0;
            time_t created;
        }
        this(DHTId old_id) {
            last_seen = DHT.now;
            
            seen_as = [old_id];
            
            version(statistics)
                created = DHT.now;
        }
    }

    private struct BlacklistAddress {
        time_t last_seen;
        version (statistics){
            uint hits = 0;
            uint[string] why;
            time_t created;
        }
        this(ubyte throwaway) {
            last_seen = DHT.now;
            
            version(statistics)
                created = DHT.now;
        }
        
    }

    // Get the sister DHT
    protected static @property DHTInfo* other_pinfo(DHTInfo* this_pinfo) {
        if (this_pinfo is &info)
            return &info6;
        else if (this_pinfo is &info6)
            return &info;
        else
            assert(0);
    }

    protected bool apply_throttling() @property {
        if (throttling_tokens == 0) {
            if (last_throttling_check == now)
                return true;

            throttling_tokens = min(
                cast(ushort)(now - last_throttling_check) * globals.throttling_per_sec,
                globals.throttling_max_bucket);
            last_throttling_check = now;
        }
        --throttling_tokens;
        return false;
    }
    // Get the desired number of good nodes closest to the target
    // This also covers pathological cases where the closest nodes
    // are in the neighbouring buckets, or the target bucket is empty.
    private ubyte[] gather_closest_nodes(DHT.DHTInfo* pinfo, DHTId target, uint howmany) {
        auto nodes = appender!(DHTNode[])();
        DHTBucket wb;
        uint collected;

        // Start with target's node
        DHTBucket b = DHT.find_bucket(pinfo, target);
        for (auto n = b.nodes.first; n !is null ; n = n.next)
            if (n.is_good)
                nodes ~= n;

        // walk left until at least 8 left nodes collected
        collected = 0;
        for (wb = b.prev; wb !is null ; wb = wb.prev) {
            for (auto n = wb.nodes.first; n; n = n.next)
                if (n.is_good) {
                    nodes ~= n;
                    collected++;
                }
            if (collected >= howmany)
                break;
        }

        // walk right until at least 8 right nodes collected
        collected = 0;
        for (wb = b.next; wb !is null; wb = wb.next) {
            for (auto n = wb.nodes.first; n; n = n.next)
                if (n.is_good) {
                    nodes ~= n;
                    collected++;
                }
            if (collected >= howmany)
                break;
        }

        DHTNode[] topn = DHTNode.closest_topn(target, nodes.data, howmany);
	
        // Convert into bin blob
        auto blob = appender!(ubyte[])();
        foreach (node; topn) {
            blob ~= node.id.id[];
            blob ~= to_blob(node.address);
        }

        return blob.data;
    }
    
    protected ubyte[] gather_closest_nodes_for_reply(DHT.DHTInfo* pinfo, DHTId target, uint howmany) {
        return gather_closest_nodes(pinfo,target,howmany);
    }
    
    // IP check:
    // This uses a "voting" mechanism which stores the last n 
    // IP responses by peers. The IP with the most votes wins.
    protected void ip_check(DHTInfo* pinfo,ubyte[] apparent_ip){
        // remove port part & check if valid
	switch(apparent_ip.length){
	    case 4, 16: 
	        break;
	    case 6: 
	        apparent_ip = apparent_ip[0..4];
		break;
	    case 18: 
	        apparent_ip = apparent_ip[0..16];
		break;
	    default:
	        fLog.info("Peer provided bad IP address");
		return;
	    }

        if(pinfo.ip_voting){ // an IP vote is ongoing
	    pinfo.own_ip_vote[pinfo.ip_voting_num++] = apparent_ip.dup;
	    
	    if(pinfo.ip_voting_num == pinfo.ip_voting_size){ // vote finished
	        evaluate_ip_votes(pinfo);
		pinfo.ip_voting = false;
	    }
	} else if(apparent_ip != pinfo.own_ip){ // Start new vote
	    fLog.trace("New " ~ (pinfo.is_v6 ? "IPv6" : "IPv4" ) ~ " vote started - someone thinks we're " ~ to_address(apparent_ip).toAddrString());
	    pinfo.ip_voting_num = 1;
            pinfo.ip_voting = true;
            pinfo.own_ip_vote[0] = apparent_ip.dup;	    
	}
    }
    protected void evaluate_ip_votes(DHTInfo* pinfo){
        uint[ubyte[]] vote_map;
	
	foreach(vote; pinfo.own_ip_vote)
            ++vote_map[vote.idup];
	
	ubyte[] top_vote;
	uint top_count=0;
	
	foreach(choice; vote_map.byKeyValue())
	    if(choice.value>top_count){
	        top_count = choice.value;
		top_vote = choice.key.dup;
	    }
	fLog.trace((pinfo.is_v6 ? "IPv6" : "IPv4" ) ~ " vote finished. The winner is: ",top_vote.to_address().toAddrString());
	
	if(top_vote != pinfo.own_ip){
	    fLog.warning((pinfo.is_v6 ? "IPv6" : "IPv4" ) ~ " address change detected: from ",pinfo.own_ip.to_address().toAddrString()," to ",top_vote.to_address().toAddrString());
	    pinfo.own_ip = top_vote.dup; 
            id_check(pinfo); 
        } else 
	    fLog.trace("No " ~ (pinfo.is_v6 ? "IPv6" : "IPv4" ) ~ " address change.");
    }
    public void id_check(){
        if(want & DHTProtocol.want4)
	    id_check(&info);
        if(want & DHTProtocol.want6)
	    id_check(&info6);
    }
    protected void id_check(DHTInfo* pinfo){
        if(is_id_by_ip(pinfo.myid,pinfo.own_ip)){
	    fLog.trace("No ID change necessary for ",pinfo.is_v6 ? "IPv6" : "IPv4");
	    return;
	} else {
	    // Preserve existing nodes
	    NodeInfo[] preserved_nodes = DHT.get_nodes(pinfo.is_v6 ? DHTProtocol.want6 : DHTProtocol.want4, 9999, 9999);
	    pinfo.reset_buckets();
	    pinfo.myid = id_by_ip(pinfo.own_ip);
	    fLog.info("ID change for ",pinfo.is_v6 ? "IPv6" : "IPv4", " to ", pinfo.myid);
	    insert_node(preserved_nodes);
	    // Final step: Boot search
	    boot_search(pinfo.is_v6 ? DHTProtocol.want6 : DHTProtocol.want4);
	}
    }
    
};

// A simple double-linked list
// T must contain T* next, prev for structs and T next, prev for classes
public struct DoubleList(T) {
    static if (is(T == class)) // classes are always references
        alias TP = T;
    else
        alias TP = T*;

    TP first;
    TP last;
    ushort num;

    void reset(){
        TP nexte;
        for(auto e = first; e !is null; e = nexte){
	    nexte = e.next;
	    e.next = e.prev = null;
	}
        first = last = null;
        num = 0;	
    }
    
    void addBack(TP t) {
        if (last !is null)
            last.next = t;
        else
            first = t;

        t.prev = last;
        t.next = null;
        last = t;
        num++;
    }

    void addFront(TP t) {
        if (first !is null)
            first.prev = t;
        else
            last = t;

        t.next = first;
        t.prev = null;
        first = t;
        num++;
    }

    void remove(TP e) {
        if (e.next)
            e.next.prev = e.prev;
        else
            last = e.prev;

        if (e.prev)
            e.prev.next = e.next;
        else
            first = e.next;
	e.next = e.prev = null;    
        num--;
    }
}

// A bucket of nodes. Nodes are sorted chronologically (oldest and most permanent first)
public class DHTBucket {
    public DHTBucket next, prev;
    public time_t age;
    private DHTId lower;

    alias DHTNodeList = DoubleList!DHTNode;
    alias DHTCache = DoubleList!CacheEntry;

    public DHTNodeList nodes;
    private DHT.DHTInfo* info;
    private DHTCache cache;
    public bool locked_for_good_ids = false;

    private struct CacheEntry {
        CacheEntry* next, prev;
        Address address;
        this(Address a) {
            address = a;
        }
    }

    public this(DHTId new_lower, DHT.DHTInfo* i) {
        lower = new_lower;
        age = DHT.now;
        info = i;
    }

    private void split() {
        fLog.info("Splitting");
        //fLog.trace("Before Split:\n", toString());

        DHTId new_id = middle;
        DHTNodeList oldnodes = nodes;
        nodes = nodes.init;

        DHTBucket newb = new DHTBucket(new_id, info);
        newb.age = age;

        if (next)
            next.prev = newb;
        else
            info.buckets.last = newb;

        newb.next = next;
        newb.prev = this;
        next = newb;
        info.buckets.num++;

        DHTNode n = oldnodes.first;
        while (n) {
            auto nx = n.next;
            if (n.id >= new_id) { // new bucket
                newb.nodes.addBack(n);
                n.bucket = newb;
            } else
                nodes.addBack(n);

            n = nx;
        }

        if (info.myid >= new_id)
            info.my_bucket = newb;

        send_cached_ping(DHT.globals.bucket_cache_size); // empty the cache
        //fLog.trace("After Split:\n", toString(), newb.toString());
    }

    private @property DHTId middle() {
        int bit1 = lower.lowbit;
        int bit2 = next ? next.lower.lowbit : -1;
        int bit = max(bit1, bit2) + 1;

        assert(bit < 160);

        DHTId new_id = lower;

        new_id.id[bit / 8] |= (0x80 >> (bit % 8));
        return new_id;
    }

    private @property DHTId random() {
        int bit1 = lower.lowbit;
        int bit2 = next ? next.lower.lowbit : -1;
        int bit = max(bit1, bit2) + 1;

        assert(bit < 160);

        DHTId new_id = lower;

        new_id.id[bit / 8] = lower.id[bit / 8] & (0xFF00 >> (bit % 8));
        new_id.id[bit / 8] |= uniform(0, 255) & 0xFF >> (bit % 8);

        for (int i = bit / 8 + 1; i < 20; i++)
            new_id.id[i] = uniform(0, 255) & 0xff;

        return new_id;
    }

    public @property override string toString() {
        auto a = appender!string();
        a ~= lower.toString(false) ~ (locked_for_good_ids ? "T" : "" ) ~  " (" ~ to!string(nodes.num) ~ "/" ~ to!string(DHT.globals.bucket_size)~")" ~
	" age: " ~ age.to_ascii() ~ (
            this == info.my_bucket ? " (mine)" : "") ~ (
            cache.num ? (" (cached " ~ to!string(cache.num) ~ ")") : "") ~ " " ~ to!string(
            lower.common_bits(info.myid)) ~ " bits\n";
        for (auto n = nodes.first; n; n = n.next)
            a ~= "  " ~ n.toString() ~ "\n";

        return a.data;
    }

    // This uses first the most recent head entry - it should have the
    // the highest chance to reply with a pong. So effectively the 
    // cache is a stack with a size limit.
    public void send_cached_ping(int howmany = 1) {
        while (cache.num > 0 && howmany > 0) {
            fLog.info("Sending ping to cached node.");
            DHTNode.send_ping(info.s, cache.first.address);
            cache.remove(cache.first);
            --howmany;
        }
    }

    private DHTNode random_node() {
        if (nodes.num == 0)
            return null;

        uint i = uniform(0, nodes.num);
        DHTNode n;
        for (n = nodes.first; i > 0; n = n.next) {
            --i;
        }
        return n;
    }

    public void store_cache(Address a) {
        CacheEntry* ce = new CacheEntry(a);
        cache.addFront(ce);
        if (cache.num > DHT.globals.bucket_cache_size)
            cache.remove(cache.last);
    }
};

// A single node. 
// All send_ ... methods are in this class.
//

class DHTNode {
    enum Reliability : ubyte {
        dubious = 0,
        sent = 1,
        replied = 2
    }

    public DHTNode next, prev;
    public DHTId id;
    public DHTId distance; // searching & sorting
    public Address address;
    public time_t first_seen, last_seen, last_replied, last_pinged;
    public ushort ping_count;
    public DHTBucket bucket;
    bool   id_matches_ip;
    
    public this(DHTId i, Address a, DHTBucket b,bool know_id_status=false,bool id_status = false) {
        id = i;
        address = a;
        first_seen = DHT.now;
        last_seen = last_replied = last_pinged = 0;
        ping_count = 0;
        bucket = b;
	if(know_id_status)
	    id_matches_ip = id_status;
	else
	    id_matches_ip = is_id_by_ip(id,to_blob(a));
    }

    public @property bool is_good() {
        return ping_count <= 2 && last_replied >= DHT.now - 7200 && last_seen >= DHT.now - 900;
    }

    // used in messages
    private static const ubyte[][DHTProtocol.max + 1] wantchoice = [
        DHTProtocol.nowant : [], 
        DHTProtocol.want4  : "4:wantl2:n4e".representation,
        DHTProtocol.want6  : "4:wantl2:n6e".representation,
        DHTProtocol.want46 : "4:wantl2:n42:n6e".representation,];

    public void send_ping() {
        send_ping(bucket.info.s, address);
        ping_count++;
        last_pinged = DHT.now;
    }

    public static void send_ping(Socket s, Address a) {
        static const ubyte[] head = "d1:ad2:id20:".representation;
        static const ubyte[] tail = "1:q4:ping1:t4:pn\x00\x001:y1:qe".representation;
	DHT.DHTInfo* pinfo = a.addressFamily == AddressFamily.INET ? &DHT.info : &DHT.info6; 

	ubyte[] blob = a.to_blob();
	
        auto msg = appender!(ubyte[])();
        msg ~= head ;
	msg ~= pinfo.myid.id[];
	msg ~= (blob.length == 6 ? "e2:ip6:".representation : "e2:ip18:".representation);
        msg ~= blob;
	msg ~= tail;
	
        s.sendTo(msg.data, cast(SocketFlags) 0, a);
        version (statistics)
            update_statistics(s, msg.data.length);
	version(protocol_trace){
	    fLog.info("Outgoing:\n",to_ascii(msg.data,true));
	    fLog.info("Outgoing:\n",bencode2ascii(msg.data));
	}
    }

    public static void send_find_node(DHT.DHTInfo* pinfo, DHTtid tid, DHTId target,
        Address address, DHTProtocol want) {
        static const ubyte[] part1 = "d1:ad2:id20:".representation;
        static const ubyte[] part2 = "6:target20:".representation;
        static const ubyte[] part3 = "1:q9:find_node1:t4:".representation;
        static const ubyte[] part4 = "1:y1:qe".representation;

	ubyte[] blob = address.to_blob();
	
        auto msg = appender!(ubyte[])();
        msg ~= part1;
        msg ~= pinfo.myid.id[];
        msg ~= part2;
        msg ~= target.id[];
        msg ~= wantchoice[want];
	msg ~= (blob.length == 6 ? "e2:ip6:".representation : "e2:ip18:".representation);
        msg ~= blob;
        msg ~= part3;
        msg ~= tid.tid[];
        msg ~= part4;

        pinfo.s.sendTo(msg.data, cast(SocketFlags) 0, address);
        version (statistics)
            update_statistics(pinfo, msg.data.length);
	version(protocol_trace)
	    fLog.info("Outgoing:\n",bencode2ascii(msg.data));
    }

    public static void send_announce_peer(DHT.DHTInfo* pinfo, Address address,
        DHTtid tid, DHTId info_hash, ubyte[] token, ushort port) {
        static const ubyte[] part1 = "d1:ad2:id20:".representation;
        static const ubyte[] part2 = "9:info_hash20:".representation;
        static const ubyte[] part3 = "4:porti".representation;
        static const ubyte[] part4 = "e5:token".representation;
        static const ubyte[] part5 = "1:q13:announce_peer1:t4:".representation;
        static const ubyte[] part6 = "1:y1:qe".representation;

	ubyte[] blob = address.to_blob();
	
        auto msg = appender!(ubyte[])();
        msg ~= part1;
        msg ~= pinfo.myid.id[];
        msg ~= part2;
        msg ~= info_hash.id[];
        msg ~= part3;
        msg ~= cast(ubyte[]) to!string(port);
        msg ~= part4;
        msg ~= cast(ubyte[]) to!string(token.length);
        msg ~= ':';
        msg ~= token;
	msg ~= (blob.length == 6 ? "e2:ip6:".representation : "e2:ip18:".representation);
        msg ~= blob;
        msg ~= part5;
        msg ~= tid.tid[];
        msg ~= part6;

        pinfo.s.sendTo(msg.data, cast(SocketFlags) 0, address);
        version (statistics)
            update_statistics(pinfo, msg.data.length);
	version(protocol_trace)
	    fLog.info("Outgoing:\n",bencode2ascii(msg.data));
    }

    public void send_find_node(DHTtid tid, DHTId target, DHTProtocol want) {
        send_find_node(bucket.info, tid, target, address, want);
    }

    public static void send_get_peers(DHT.DHTInfo* pinfo, Address address, DHTtid tid,
        DHTId info_hash, DHTProtocol want) {
        static const ubyte[] part1 = "d1:ad2:id20:".representation;
        static const ubyte[] part2 = "9:info_hash20:".representation;
        static const ubyte[] part3 = "1:q9:get_peers1:t4:".representation;
        static const ubyte[] part4 = "1:y1:qe".representation;

	ubyte[] blob = address.to_blob();
	
        auto msg = appender!(ubyte[])();
        msg ~= part1;
        msg ~= pinfo.myid.id[];
        msg ~= part2;
        msg ~= info_hash.id[];
        msg ~= wantchoice[want];
	msg ~= (blob.length == 6 ? "e2:ip6:".representation : "e2:ip18:".representation);
        msg ~= blob;
        msg ~= part3;
        msg ~= tid.tid[];
        msg ~= part4;

        pinfo.s.sendTo(msg.data, cast(SocketFlags) 0, address);
        version (statistics)
            update_statistics(pinfo, msg.data.length);
	version(protocol_trace)
	    fLog.info("Outgoing:\n",bencode2ascii(msg.data));
    }

    public alias send_closest_nodes = send_nodes_peers; // identical

    public static void send_nodes_peers(DHT.DHTInfo* pinfo, Address address,
        ubyte[] tid, DHTId target, DHTProtocol want, ubyte[] token = [], ubyte[] peers = []) {
        ubyte[] nodes, nodes6;

	ubyte[] blob = address.to_blob();
	
        if (want == DHTProtocol.nowant) { // no preference, use native
            if (pinfo.is_v6)
                want = DHTProtocol.want6;
            else
                want = DHTProtocol.want4;
        }

        if (want & DHTProtocol.want4)
            nodes = DHT.get_instance.gather_closest_nodes_for_reply(&DHT.info, target, 8);

        if (want & DHTProtocol.want6)
            nodes6 = DHT.get_instance.gather_closest_nodes_for_reply(&DHT.info6, target, 8);

        static const ubyte[] part0 = "d2:ip".representation;
        static const ubyte[] part1 = "1:rd2:id20:".representation;
        static const ubyte[] part2 = "6:valuesl".representation;
        static const ubyte[] part3 = "e".representation;
        static const ubyte[] part4 = "1:y1:re".representation;

        auto msg = appender!(ubyte[])();

        msg ~= part0;
	msg ~= (blob.length == 6 ? "6:".representation : "18:".representation);
        msg ~= blob;
	
	
        msg ~= part1;
        msg ~= pinfo.myid.id[];
        if (nodes.length > 0) {
            msg ~= cast(ubyte[])("5:nodes" ~ to!string(nodes.length) ~ ":");
            msg ~= nodes;
        }
        if (nodes6.length > 0) {
            msg ~= cast(ubyte[])("6:nodes6" ~ to!string(nodes6.length) ~ ":");
            msg ~= nodes6;
        }
        if (token.length > 0) {
            msg ~= cast(ubyte[])("5:token" ~ to!string(token.length) ~ ":");
            msg ~= token;
        }
        if (peers.length > 0) {
            ushort entrylen = pinfo.is_v6 ? 18 : 6;
            ubyte[] len_header = cast(ubyte[]) to!string(entrylen) ~ ':';

            fLog.info(
                "  Sent " ~ to!string(peers.length / entrylen) ~ " " ~ (pinfo.is_v6 ? "IPV6"
                : "IPV4") ~ " peers");

            msg ~= part2;

            while (peers.length > 0) {
                msg ~= len_header;
                msg ~= peers[0 .. entrylen];
                peers = peers[entrylen .. $];
            }

            msg ~= part3;
        }

        msg ~= cast(ubyte[])("e1:t" ~ to!string(tid.length) ~ ":");
        msg ~= tid;
        msg ~= part4;

        fLog.info(
            "  Sent (" ~ to!string(nodes.length / 26) ~ "+" ~ to!string(nodes6.length / 38) ~ ") nodes");

        pinfo.s.sendTo(msg.data, cast(SocketFlags) 0, address);
        version (statistics)
            update_statistics(pinfo, msg.data.length);
	version(protocol_trace)
	    fLog.info("Outgoing:\n",bencode2ascii(msg.data));
    }

    version (statistics) {
        private static void update_statistics(Socket s, size_t msg_size) {
            update_statistics(
                s.addressFamily == AddressFamily.INET ? &DHT.info : &DHT.info6, msg_size);
        }

        private static void update_statistics(DHT.DHTInfo* pinfo, size_t msg_size) {
            pinfo.data_send_num++;
            pinfo.data_send_net += msg_size;
            pinfo.data_send_gross += msg_size + pinfo.header_size;
        }
    }


    // Return the nodes closest to target
    private static DHTNode[] closest_topn(DHTId target, DHTNode[] nodes, uint topn) {
        if (nodes.length <= topn)
            return nodes;

        // populate each node's distance field...
        foreach (node; nodes)
            node.distance = node.id.distance_to(target);

        // ...to use it in topN
        nodes.topN!"a.distance < b.distance"(topn); // topN! is non-sorting, but that's fine.
        return nodes[0 .. topn];
    }

    // send_pong and send_peer_announced are identical, they just return the TID    
    public alias send_pong = send_peer_announced;

    public static void send_peer_announced(DHT.DHTInfo* pinfo, Address address, ubyte[] tid) {
        static const ubyte[] part0 = "d2:ip".representation;
        static const ubyte[] part1 = "1:rd2:id20:".representation;
        static const ubyte[] part2 = "1:y1:re".representation;
        auto msg = appender!(ubyte[])();

	ubyte[] blob = address.to_blob();

        msg ~= part0;
	msg ~= cast(ubyte[]) to!string(blob.length);
	msg ~= ':';
        msg ~= blob;
	
        msg ~= part1;
        msg ~= pinfo.myid.id[];

        msg ~= cast(ubyte[])("e1:t" ~ to!string(tid.length) ~ ":");
        msg ~= tid;
        msg ~= part2;

        pinfo.s.sendTo(msg.data, cast(SocketFlags) 0, address);
        version (statistics)
            update_statistics(pinfo, msg.data.length);
	version(protocol_trace)
	    fLog.info("Outgoing:\n",bencode2ascii(msg.data));
    }

    public void pinged() {
        last_pinged = DHT.now;
        ++ping_count;
        if (ping_count >= DHT.globals.bucket_max_ping_count)
            bucket.send_cached_ping();

    }

    public @property override string toString() {
        static char[512] buf;

        // Only show blacklisted nodes if statistics are on & blacklisting is disabled.
        version (disable_blacklisting)
            version (statistics)
                return to!string(sformat(buf,
                    "%s %-*s age: %-6s ls: %-6s lr: %-6s lp: %-6s pc: %d%s%s%s",
                    id.toString() ~ (id_matches_ip ? "T" : " "), bucket.info.is_v6 ? 47 : 21,
                    to!string(address), first_seen.to_ascii(),
                    last_seen.to_ascii(), last_replied.to_ascii(),
                    last_pinged.to_ascii(), ping_count,
                    (is_good ? " (good)" : ""),
                    (
                    bucket.info.my_bucket == bucket ? " (" ~ to!string(
                    id.common_bits(pinfo.myid)) ~ " bits)" : ""),
                    DHT.is_really_blacklisted(bucket.info, address) ? " (blacklisted)" : ""));

	DHTId* myid = address.addressFamily == AddressFamily.INET6 ? &DHT.info6.myid : &DHT.info.myid;
		    
        return to!string(sformat(buf,
            "%s %-*s age: %-6s ls: %-6s lr: %-6s lp: %-6s pc: %d%s%s", id.toString() ~ (id_matches_ip ? "T" : " "),
            bucket.info.is_v6 ? 47 : 21,
            to!string(address), first_seen.to_ascii(), last_seen.to_ascii(),
            last_replied.to_ascii(), last_pinged.to_ascii(), ping_count,
            (is_good ? " (good)" : ""),
            (
            bucket.info.my_bucket == bucket ? " (" ~ to!string(
            id.common_bits(*myid)) ~ " bits)" : "")));
    }
};

// A simple scheduler class which handles recurring maintenance jobs
public class Scheduler(id_t = uint) {
    private alias run_t = void delegate();
    protected struct entry {
        id_t id;
        run_t runme;
        time_t nextrun, frequency;
    }

    protected entry*[id_t] entries;
    public void add(id_t newid, run_t runme, time_t frequency, time_t nextrun = 0, time_t now = time(null)) {
        entry* ne = new entry;
        entries[newid] = ne;
        ne.runme = runme;
        ne.frequency = frequency;
        ne.nextrun = now + nextrun;
        ne.id = newid;
    }

    public void reschedule_earlier(id_t id, time_t delta_t, time_t now = time(null)) {
        assert(id in entries);
        time_t nextrun = now + delta_t;
        auto e = entries[id];
        if (e.nextrun > nextrun) {
            fLog.trace("Rescheduling ", id, " from ", e.nextrun, " to ", nextrun);
            e.nextrun = nextrun;
        }
    }

    public void reschedule_later(id_t id, time_t delta_t, time_t now = time(null)) {
        assert(id in entries);
        time_t nextrun = now + delta_t;
        auto e = entries[id];
        if (e.nextrun < nextrun) {
            fLog.trace("Rescheduling ", id, " from ", to_ascii(e.nextrun),
                " to ", to_ascii(nextrun));
            e.nextrun = nextrun;
        }
    }
    // run() checks & runs the tasks and calculates the time until the next call is needed
    public time_t run(time_t now = time(null)) {
        foreach (e; entries)
            if (e.nextrun <= now) {
                e.nextrun = now + e.frequency; // allow runme() code to re-schedule
                fLog.trace("Scheduler: ", e.id);
                e.runme();
            }
        time_t nextrun = time_t.max;
        foreach (e; entries)
            if (e.nextrun < nextrun)
                nextrun = e.nextrun;
        return nextrun > now ? nextrun - now : 0;
    }
}

// 160 bit ID/hashref and various ops
public struct DHTId {
    union {
        ubyte[20] id;
        uint[5] id32; // used for XOR speedup only where endianness doesn't matter
    };

    this(const ubyte[] new_id) {
        assert(new_id.length == 20);
        id = new_id.dup;
    }

    this(string new_id) {
        ubyte[20] binary_id;
        assert(new_id.length == 40); // Hex string
        for(auto i = 0; i < 20; i++){
	    string hexbyte = new_id[0..2];
	    formattedRead(hexbyte,"%x",&binary_id[i]);
	    new_id = new_id[2..$];
	}
	this(binary_id);
    }

    // used for >, <, ==
    int opCmp(DHTId other) {
        return memcmp(id.ptr, other.id.ptr, 20);
    }

    @property int lowbit() {
        int i, j;
        for (i = 19; i >= 0; i--)
            if (id[i] != 0)
                break;

        if (i < 0)
            return -1;

        for (j = 7; j >= 0; j--)
            if ((id[i] & (0x80 >> j)) != 0)
                break;

        return 8 * i + j;
    }

    @property string toString(bool say_empty = true) {
        static char[40] a;
        if (this == zero && say_empty)
            return "(empty)";
        return to!string(sformat(a, "%08x%08x%08x%08x%08x", htonl(id32[0]),
            htonl(id32[1]), htonl(id32[2]), htonl(id32[3]), htonl(id32[4])));
    }

    DHTId distance_to(const DHTId other) const {
        DHTId delta;
        for (int i = 0; i < 5; i++)
            delta.id32[i] = id32[i] ^ other.id32[i];
        return delta;
    }

    uint common_bits(const DHTId other) const {
        int i, j;
        ubyte xor;
        for (i = 0; i < 20; i++) {
            if (id[i] != other.id[i])
                break;
        }

        if (i == 20)
            return 160;

        xor = id[i] ^ other.id[i];

        j = 0;
        while ((xor & 0x80) == 0) {
            xor <<= 1;
            j++;
        }

        return 8 * i + j;
    }

    static DHTId random() @property {
        DHTId id;

        foreach (ref i32; id.id32)
            i32 = uniform(i32.min, i32.max);

        return id;
    }

    size_t toHash() const pure nothrow @trusted {
        return id.hashOf();
    }

    bool opEquals(ref const DHTId s) const @safe pure nothrow {
        return id32 == s.id32;
    }

    static DHTId zero = DHTId(cast(ubyte[]) hexString!"0000000000000000000000000000000000000000");
    static DHTId blacklisted = DHTId(
        cast(ubyte[]) hexString!"00000000000000000000000000000000000000ff");
};

// TID / Transaction ID and related operations.
public struct DHTtid {
    static ushort tsequence = 0;
    union {
        ubyte[4] tid;
        struct {
            char[2] tcode;
            ushort tkey;
        };
    };

    // Use a random start for search TIDs (get_peers, announce peers)
    static this() {
        tsequence = uniform(2, 0xf000) & 0xffff;
    }

    this(string t, ushort s = ++tsequence) {
        assert(t.length == 2);
        tcode[0] = t[0];
        tcode[1] = t[1];
        tkey = s;
    }

    this(ubyte[] ntid) {
        assert(ntid.length == 4);
        tid = ntid;
    }

    @property string toString() {
        return to!string(tcode) ~ to!string(tkey);
    }
    // for hashing
    size_t toHash() const pure nothrow @trusted {
        return tid.hashOf();
    }

    bool opEquals(ref const DHTtid s) const @safe pure nothrow {
        return s.tid == tid;
    }
};

static string to_ascii(in ubyte[] ub, bool dots = false) {
    auto a = appender!string();
    if(dots)
		foreach (c; ub) {
			if (c == 0)
				a ~= ".";
			else if (isPrintable(to!char(c)))
				a ~= to!char(c);
			else
				a ~= ".";
		}
	else
		foreach (c; ub) {
			if (c == 0)
				a ~= "\\0";
			else if (isPrintable(to!char(c)))
				a ~= to!char(c);
			else
				formattedWrite(a, "\\x%02x", c);
		}
    return a.data;
}

static string to_ascii(time_t point) {
    if (point == 0)
        return "never";

    time_t delta;
    if (DHT.now >= point)
        delta = DHT.now - point;
    else
        delta = point - DHT.now;

    time_t days, hours, minutes, seconds;
    static char[32] buf;

    if (delta < 60)
        return to!string(sformat(buf, "%ds", delta));

    seconds = delta % 60;
    delta /= 60;

    if (delta < 60)
        return to!string(sformat(buf, "%dm%ds", delta, seconds));

    minutes = delta % 60;
    delta /= 60;
    if (delta < 24)
        return to!string(sformat(buf, "%dh%dm", delta, minutes));

    hours = delta % 24;
    days = delta / 24;

    return to!string(sformat(buf, "%dd%dh", days, hours));
}

// Reflect's C's struct sockaddr for both IPv4 and IPv6
private struct AddressBlob {
    union {
        struct {
            uint addr4;
            ushort port4;
        };
        ubyte[4] ablob4;
        ubyte[6] blob4;
        struct {
            ubyte[16] addr6;
            ushort port6;
        };
        alias ablob6 = addr6;
        ubyte[18] blob6;
    };
    size_t toHash() const pure nothrow @trusted {
        return blob6.hashOf();
    }
}

// Convert AddressBlob to Address instance	
public Address to_address(const ubyte[] buf) {
    AddressBlob blob;

    switch(buf.length){
        case 4:
	    blob.ablob4 = buf;
	    return new InternetAddress(ntohl(blob.addr4),cast(ushort)0);
	case 6: 
            blob.blob4 = buf;
            return new InternetAddress(ntohl(blob.addr4), ntohs(blob.port4));
	case 16:
	    blob.ablob6 = buf;
	    return new Internet6Address(blob.addr6, cast(ushort)0);
	case 18:
            blob.blob6 = buf;
            return new Internet6Address(blob.addr6, ntohs(blob.port6));
	default:
            assert(0);
    }
}

// Convert address to blob used as key in blacklist hash
static ubyte[] to_blacklistblob(Address a) {
    AddressBlob* blob = new AddressBlob;

    switch(a.addressFamily){
        case AddressFamily.INET: // v4
            blob.addr4 = htonl((cast(InternetAddress) a).addr);
            return blob.ablob4;
        case AddressFamily.INET6: // v6
            blob.addr6 = (cast(Internet6Address) a).addr;
            // 6to4: blank out last 80 bits of 6to4 address (2002::/16)
            if (blob.addr6[0 .. 2] == [0x20, 0x02])
                blob.addr6[6 .. 16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
            // Teredo: blank out anything but the obfuscated public IPv4 of Teredo address (2001::/32)
            else if (blob.addr6[0 .. 4] == [0x20, 0x01, 0, 0])
                blob.addr6[4 .. 12] = [0, 0, 0, 0, 0, 0, 0, 0];
            return blob.ablob6;
	default:
	    assert(0);
    }
}

// Convert address blob to blacklist blob used as key in blacklist hash
static ubyte[] to_blacklistblob(ubyte[] ablob) {
    AddressBlob* blob = new AddressBlob;

    switch(ablob.length){
        case 6: // V4
            blob.ablob4 = ablob[0..4];
            return blob.ablob4;
        case 18: // V6
            blob.addr6 = ablob[0..16];
            // 6to4: blank out last 80 bits of 6to4 address (2002::/16)
            if (blob.addr6[0 .. 2] == [0x20, 0x02])
                blob.addr6[6 .. 16] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
            // Teredo: blank out anything but the obfuscated public IPv4 of Teredo address (2001::/32)
            else if (blob.addr6[0 .. 4] == [0x20, 0x01, 0, 0])
                blob.addr6[4 .. 12] = [0, 0, 0, 0, 0, 0, 0, 0];
            return blob.ablob6;
        default:
            assert(0);
    }
}

public ubyte[] to_blob(Address a) {
    AddressBlob* blob = new AddressBlob;

    switch(a.addressFamily){
        case AddressFamily.INET: // v4
            InternetAddress ax = cast(InternetAddress) a;
            blob.addr4 = htonl(ax.addr());
            blob.port4 = htons(ax.port);
            return blob.blob4;
        case AddressFamily.INET6: // v6
            Internet6Address ax = cast(Internet6Address) a;
            blob.addr6 = ax.addr;
            blob.port6 = htons(ax.port);
            return blob.blob6;
	default:
	    assert(0);
    }
}

static AddressBlob to_addressblob(Address a) {
    AddressBlob* blob = new AddressBlob;

    switch(a.addressFamily){
        case AddressFamily.INET: // v4
            InternetAddress ax = cast(InternetAddress) a;
            blob.addr4 = htonl(ax.addr);
            blob.port4 = htons(ax.port);
            break;
        case AddressFamily.INET6: // v6
            Internet6Address ax = cast(Internet6Address) a;
            blob.addr6 = ax.addr;
            blob.port6 = htons(ax.port);
            break;
	default:
	    assert(0);
    }
    return *blob;
}

static Address to_v4(ubyte[] blob){
    AddressBlob a;
    switch(blob.length){
        case 4:
	case 6: 
	    return null;
	case 16: 
	    a.ablob6 = blob;
	    break;
	case 18:
	    a.blob6 = blob;
	    break;
	default:  
            assert(0);
    }
    AddressBlob v4;
    if (a.addr6[0 .. 2] == [0x20, 0x02]) // 6to4
        v4.ablob4 = a.ablob6[2..6];
    else if (a.addr6[0 .. 4] == [0x20, 0x01, 0, 0]) // Teredo
        for(auto i=0;i<4;i++)
	    v4.ablob4[i] = a.ablob6[i+12] ^ 0xff;
    else
        return null; // regular IPv6

    return new InternetAddress(ntohl(v4.addr4),ntohs(a.port6));
}

// Convert UnknownAddressReference
public Address to_subtype(Address a){
    if (typeid(a) == typeid(InternetAddress)) {}
    else if(typeid(a) == typeid(Internet6Address)) {}
    else if(typeid(a) == typeid(UnknownAddressReference)) {
	if(a.addressFamily == AddressFamily.INET){
	    a = new InternetAddress(*(cast(sockaddr_in*)a.name));
	} else if(a.addressFamily == AddressFamily.INET6){
	    a = new Internet6Address((cast(sockaddr_in6*)a.name).sin6_addr.s6_addr, 
	    ntohs((cast(sockaddr_in6*)a.name).sin6_port));
	} else
	    assert(0);
	
    } else assert(0);
    return a;
}


// Message debugging
//
//

alias StringAppender = typeof(appender!string());

static string bencode2ascii(ubyte[] buf){
    StringAppender output = appender!string();
    output ~= to_ascii(buf,true) ~ "\n";
    uint cur = 0; 
    // ignore trailing junk byte
    while(cur < buf.length - 1 && buf[cur] != '\0')
        bencode2ascii_step(buf,cur,output);
    return output.data.dup;
}

static void bencode2ascii_step(ubyte[] buf, ref uint cur, ref StringAppender output, uint ind=0){
    switch(buf[cur]){
	case 'd': // Dictionary: string-value pairs
	    output ~= "{\n";
	    cur++;
	    while(buf[cur]!='e'){
	        output.indent(ind+2);
		output ~= bencode2ascii_string(buf,cur);
		output ~= "=";
		bencode2ascii_step(buf,cur,output,ind+2);
	    }
	    output.indent(ind);
	    output ~= "}\n";
	    cur++;
	    break;
	case 'l': // List
	    output ~= "[\n";
	    cur++;
	    while(buf[cur]!='e'){
	        output.indent(ind+2);
		bencode2ascii_step(buf,cur,output,ind+2);
	    }
	    output.indent(ind);
	    output ~= "]\n";
	    cur++;
	    break;
	case 'i': // Integer
	    cur++;
            uint end = cur;
	    if(isDigit(buf[end]) || buf[end] == '-')
	        end++;
	    else 
	        throw new Exception("broken message");
	    
	    while(buf[end]!='e'){
	        if(isDigit(buf[end]))
	            end++;
	        else 
	            throw new Exception("broken message");
	    }
            output ~= cast(string) buf[cur .. end];
	    output ~= "\n";
	    cur = end + 1;
	    break;
	case '0': .. case '9': // String    
	    ubyte[] block = bencode2ascii_string(buf,cur);
	    output ~= '"';
	    output ~= to_ascii(block,true);
	    output ~= "\" ";
	    foreach(c; block)
	        output.formattedWrite("%02x",c);
		
	    switch(block.length){
	        case 4,6,16,18: 
		    output ~= ' ';     
		    output ~= to_address(block).toString();
		    break;
		default:
            }	    
		
	    output ~= "\n";
	    break;
	default: throw new Exception("broken message@" ~ to!string(cur) ~ ": \"" ~ to_ascii(buf[cur .. $]) ~ "\"");
    }	    
}

void indent(ref StringAppender output, uint spaces){
    while(spaces--)
        output ~= " ";
}

// Move cur and return string. 
static ubyte[] bencode2ascii_string(ubyte[] buf, ref uint cur){
    if(!isDigit(to!char(buf[cur])))
        throw new Exception("broken message");

    uint end=cur;
    while(end < buf.length && isDigit(to!char(buf[end])))
        end++;

    if(end >= buf.length || buf[end] != ':')
        throw new Exception("broken message");
	
    uint len = to!uint(cast(string) buf[cur .. end]);
    
    if(end + len > buf.length - 2)
        throw new Exception("broken message");
	
    cur = end + len + 1;	
	
    return buf[(end+1) .. cur];
}
	
// Security extensions against sybils - see https://libtorrent.org/dht_sec.html
//
//
	
alias CRC32C = CRC!(32u, 0x82F63B78);

    // Endianess is an issue, so we use uint
union IntBlob{
    ubyte[4] ub;
    uint     ui;
}

// Create a valid own ID by given IP
static DHTId id_by_ip(ubyte[] ip){
    ip = ip.dup;

    int num_octets;
    DHTId id;
    
    
    switch(ip.length){
        case 16, 18:
	    num_octets = 8; break;
        case 4, 6:
	    num_octets = 4; break;
	default:
	    assert(0);
    }
    
    static const ubyte[] v4_mask = [ 0x03, 0x0f, 0x3f, 0xff ];
    static const ubyte[] v6_mask = [ 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff ];
    const ubyte[] mask = num_octets == 4 ? v4_mask : v6_mask;
    
    for (int i = 0; i < num_octets; ++i)
        ip[i] &= mask[i];

    ubyte rand = cast(ubyte) uniform(0,256);
    version (limit_random_id)
        rand = 0x42;
    
    ubyte r = rand & 0x7;
    ip[0] |= r << 5;
    
    CRC32C crc32c;
    crc32c.put(ip[0..num_octets]);
    IntBlob crc;
    crc.ub = crc32c.finish;    
    // only take the top 21 bits from crc
    id.id[0] = (crc.ui >> 24) & 0xff;
    id.id[1] = (crc.ui >> 16) & 0xff;
    id.id[2] = ((crc.ui >> 8) & 0xf8) | (cast(ubyte)uniform(0,8));
    for (int i = 3; i < 19; ++i) 
        id.id[i] = cast(ubyte) uniform(0,256);
    id.id[19] = rand;
    
    return id;
}

// Check if a given ID is valid by IP	
// This checks the first 21 bits only, the rest is random.
static bool is_id_by_ip(DHTId id, ubyte[] ip){
    ip = ip.dup;

    int num_octets;

    ubyte[3] is_id = id.id[0..3];
    ubyte[3] should_id;

    switch(ip.length){
        case 16, 18:
	    num_octets = 8; break;
        case 4, 6:
	    num_octets = 4; break;
	default:
	    assert(0);
    }
    
    static const ubyte[] v4_mask = [ 0x03, 0x0f, 0x3f, 0xff ];
    static const ubyte[] v6_mask = [ 0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff ];
    const ubyte[] mask = num_octets == 4 ? v4_mask : v6_mask;

    for (int i = 0; i < num_octets; ++i)
        ip[i] &= mask[i];

    ubyte rand = id.id[19];
    ubyte r = rand & 0x7;
    ip[0] |= r << 5;
    
    CRC32C crc32c;
    crc32c.put(ip[0..num_octets]);
    IntBlob crc;
    crc.ub = crc32c.finish;    

    // Create the "should" ID - first 21 bits only
    should_id[0] = (crc.ui >> 24) & 0xff;
    should_id[1] = (crc.ui >> 16) & 0xff;
    should_id[2] = ((crc.ui >> 8) & 0xf8); // no additional random bytes here

    // zero last 3 bits of "is" ID
    is_id[2] &= 0xf8;
    
    return is_id == should_id;
}
    


	
	
	
	
	