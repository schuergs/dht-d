/**
 * dhtbootserver: Boot server based on dht-d 
 *
 *
 * Copyright (c) 2016 Stefan Schuerger
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

module dhtbootserver;

import std.array                : array, appender, join;
import std.conv                 : hexString, to;
import std.math                 : log;
import std.random               : uniform;
import std.socket               : Socket, Address, AddressFamily;
import core.stdc.time           : time, time_t;
import dht;

class DHTBootserver : DHT {
    struct globals_bs_t {
        uint bucket_size = 2048;                            // The size of the single bucket
        uint bucket_max_num = 1;                            // One bucket only
        uint bucket_max_ping_time = 60;                     // Time between pings
        uint bucket_cache_size = 128;                       // Size of each bucket's cache
        uint node_maturity_threshold = 1800;                // Minimum age of node to return it
        uint scheduler_expire_buckets = 60;                 // Service job to expire bucket entries
        uint scheduler_ping_walker = 5;                     // Walk forward and ping
        uint scheduler_random_search = 600;                 // Start a random search to gather nodes
        uint walker_steps = 64;                             // Number of nodes to ping for the walker
	uint well_filled_percentage = 95;                   // well-filled watermark
	uint bucket_lock_good_id_nodes = 50;                // The minimum number of good nodes with trusted ID to lock bucket
    };

    public static immutable globals_bs_t globals_bs;
    NodeCollector collector4, collector6;
    PingWalker ping_walker4;
    PingWalker ping_walker6;
    public static bool well_filled4 = false;
    public static bool well_filled6 = false;
    
    static DHTProtocol want_by_fill = DHTProtocol.want46; // protocols which need new nodes
    
    alias PingWalker = Walker!(DHTNode,
        (a){ // action
	    if(DHTBootserver.want_by_fill == DHTProtocol.nowant) 
	        a.send_ping(); 
	    else { 
	        a.send_find_node(DHTtid("fn", 0), DHTId.random, want_by_fill); 
		a.pinged();
	    }
	}, 
	"!a.is_good && a.last_pinged <= DHT.now - DHTBootserver.globals_bs.bucket_max_ping_time" // condition
    );

    alias NodeCollector = Collector!(DHTNode, ubyte[],
	"a.id.id ~ to_blob(a.address)", // collect append expression
	"a.is_good",                    // collect condition
	"!a.is_mature && a.bucket.nodes.first.is_mature" // reset condition
    );
    
    /**********************************************************
     * Initialise the DHT boot server.
     * Params:
     *   myID  = The DHT Id of this node
     *   sock4 = a bound IPv4 socket. null for an IPv6-only client.
     *   sock6 = a bound IPv6 socket. null for an IPv4-only client.
     * See_Also: DHT.this, callback_t, DHTId
     */

    this(DHTId myID, Socket sock4, Socket sock6) {
        // overwrite some globals values
	globals.bucket_size           = globals_bs.bucket_size;
	globals.bucket_max_ping_time  = globals_bs.bucket_max_ping_time;
	globals.bucket_max_ping_count = 99999;
	globals.bucket_max_age        = 99999;
	globals.scheduler_neighbourhood_maintenance = 99999;
	globals.scheduler_bucket_maintenance        = 99999;
	globals.bucket_cache_size     = globals_bs.bucket_cache_size;
	globals.bucket_max_num        = globals_bs.bucket_max_num;
	globals.bucket_lock_good_id_nodes = globals_bs.bucket_lock_good_id_nodes;
	
        super(myID, myID, sock4, sock6,(tp,id,ad){});

        ping_walker4 = PingWalker(&info.buckets.first.nodes);
        ping_walker6 = PingWalker(&info6.buckets.first.nodes);
	
        collector4 = NodeCollector(&info.buckets.first.nodes);
	collector6 = NodeCollector(&info6.buckets.first.nodes);
	
        scheduler.add(ScheduleType.random_search, () { new_search(DHTId.random); },
            globals_bs.scheduler_random_search, 0);
        scheduler.add(ScheduleType.ping_walker, () { ping_walker4.walk(globals_bs.walker_steps); ping_walker6.walk(globals_bs.walker_steps);}  ,
            globals_bs.scheduler_ping_walker, globals_bs.scheduler_ping_walker);
	
	want_by_fill = DHT.want;
	
    }
    

    override void parse_incoming(ubyte[] buf, Address from) {
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

	// Bootserver: If the message is initiated by a mature node, silently
	// ignore it. With a bit of luck, the node will eventually remove us from its
	// routing tables, reducing traffic.
	auto node = (wm.id in pinfo.bucket_nodes);
	if(node !is null && wm.message != DHTMessageType.reply && is_mature(*node)){
	    fLog.info("Ignoring ", wm.message, " message from mature node");
	    return;
	}
	    
        if (wm.message != DHTMessageType.reply && apply_throttling) {
            fLog.warning("Throttling applied, incoming message discarded.");
            version (statistics)
                pinfo.throttled_recv++;
            return;
        }

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
                    super.new_node(DHTId(wm.nodes[0 .. 20]), wm.nodes[20 .. 26], DHTNode.Reliability.dubious);
                    wm.nodes = wm.nodes[26 .. $];
                }
                while (wm.nodes6.length > 0) {
                    version (statistics) {
                        DHT.info6.nodes_recv++;
                        if (is_really_blacklisted(wm.nodes6[20 .. 38]))
                            DHT.info6.blacklisted_nodes_recv++;
                    }
                    super.new_node(DHTId(wm.nodes6[0 .. 20]), wm.nodes6[20 .. 38], DHTNode.Reliability.dubious);
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
                if (want == DHTProtocol.want46) {
                    auto opinfo = other_pinfo(pinfo);
                    if (opinfo is null) {
                        fLog.warning("Yikes!");
                        break;
                    }
                    auto os = find_search(opinfo, thistid);
                    if (os is null) {
                        fLog.warning("Yikes!");
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
            /* case "ap": removed for boot server */
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
                DHTId.zero.id, []); // Dummy token and no peers
            break;
        case DHTMessageType.find_node:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.info("Find node!");
            fLog.info("  Sending closest nodes (" ~ to!string(wm.want) ~ ")");
            DHTNode.send_closest_nodes(pinfo, from, wm.tid, wm.target, wm.want);
            break;
        case DHTMessageType.announce_peer:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.info("Announce Peer! - ignoring"); // Ignoring will eventually remove us from other client's routing tables
            break;
        default:
            new_node(pinfo, wm.id, from, DHTNode.Reliability.sent);
            fLog.trace("Non-implemented message type: ", wm.message);
        }

	// Perform check of our own IP
	if(wm.own_ip.length > 0)
	    ip_check(pinfo,wm.own_ip);

    }


    // Handles an incoming node (Sender of a message or get_peers/find_node data)
    // 
    override void new_node(DHTInfo* pinfo, DHTId id, Address from, DHTNode.Reliability rel) {

        fLog.trace("id=", id, " addr=", from, " rel=", rel);

        DHTNode* node = (id in pinfo.bucket_nodes);
        if (node !is null) {
	    switch(rel){
	        case node.Reliability.replied:
                    node.last_replied = now;
                    node.last_pinged = 0;
                    node.ping_count = 0;
                    node.bucket.age = now;
                    node.last_seen = now;
		    break;
                case node.Reliability.sent:
                    node.last_seen = now;
		    break;
		default:
            }
            fLog.trace("is known");
            return;
        }

	/* Bootserver: DHTNode.Reliability.sent implies an unsolicited message.
	   Only proceed if our bucket is less than the watermark.
	*/
	
        DHTBucket bucket = pinfo.buckets.first;
	if(rel == DHTNode.Reliability.sent && (pinfo.is_v6 ? well_filled6 : well_filled4))
	    return;
	
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
	
	
        if (bucket.nodes.num >= globals.bucket_size) {
            if (rel != DHTNode.Reliability.dubious) {
                bucket.store_cache(from);
                fLog.trace("Bucket full - caching");
            } else
                fLog.trace("Bucket full - no action");
            return;
        }

        /* Create new node */
        DHTNode this_node = new DHTNode(id, from, bucket,id_match_checked,id_matches_ip);
        this_node.last_seen = rel == DHTNode.Reliability.dubious ? 0 : now;
        this_node.last_replied = rel == DHTNode.Reliability.replied ? now : 0;
        pinfo.bucket_nodes[id] = this_node;
        bucket.nodes.addBack(this_node);
        // Adjust watermark
	pinfo.is_v6 ? well_filled6 : well_filled4 = ((100 * bucket.nodes.num ) / globals.bucket_size) >= globals_bs.well_filled_percentage;
        fLog.trace("Adding as new node");
    }

    // Weed out dead nodes in buckets: Remove dead nodes and try to insert each node
    // from the cache instead.
    override void expire_buckets(DHTInfo* pinfo) {
        uint removed_nodes=0;
	DHTNode nextnode;
	for (auto bucket = pinfo.buckets.first; bucket !is null; bucket = bucket.next)
	    for (auto node = bucket.nodes.first; node !is null; node = nextnode){
	        nextnode = node.next;
                if (node.ping_count > ping_count_threshold(node.first_seen)) {
                    bucket.nodes.remove(node);
                    bucket.send_cached_ping();
                    pinfo.bucket_nodes.remove(node.id);
		    ++removed_nodes;
                }
	    }
	
        if(removed_nodes > 0)	
	    fLog.info("Expired ",removed_nodes," ",pinfo.is_v6 ? "IPv6" : "IPv4", " nodes.");	
		
        // Adjust watermark
	pinfo.is_v6 ? well_filled6 : well_filled4 = ((100 * pinfo.buckets.first.nodes.num ) / globals.bucket_size) >= globals_bs.well_filled_percentage;
	// Adjust want depending on watermark: If other network is already well-filled,
	// don't ask for it anymore.

	want_by_fill = DHTProtocol.nowant;
	if(!well_filled6) 
	    want_by_fill |= DHT.want & DHTProtocol.want6;
	if(!well_filled4) 
	    want_by_fill |= DHT.want & DHTProtocol.want4;
	    
	fLog.trace("ping/send_peers policy set to ",want_by_fill," global want is ",DHT.want);    
    }
    //
    // Depending on the age of nodes, be more gentle to them:
    // A fresh node may not answer a ping twice, while a node
    // which is a day old will survive seven pings.
    // This roughly corresponds to log5(seconds).
    uint ping_count_threshold(time_t created){
        created = now - created;
	
	if(created < 120)
	    return 2;
	if(created < 600)
	    return 3;
	if(created < 3600)
	    return 4;
	if(created < 5*3600)
	    return 5;
	if(created < 86400)
	    return 6;
	return 7;
    }

    //
    // Collect nodes by walking across the bucket - nodes will only be collected
    // if they are good and have a minimum age.
    override ubyte[] gather_closest_nodes_for_reply(DHT.DHTInfo* pinfo, DHTId target, uint howmany) {
        if(pinfo.is_v6)
	    return collector6.collect(howmany);
	else
	    return collector4.collect(howmany);
    }
 };

bool is_mature(DHTNode node){
    return DHT.now - node.first_seen >= DHTBootserver.globals_bs.node_maturity_threshold;
}
 
// 
// Walks forward through a DoubleList of T until an element is found which fulfills a condition,
// then performs an action. Condition is optional. If a given reset condition (optional)
// is fulfilled, reset the walker to the start of the list.
struct Walker(T, alias action, alias condition = "true", alias reset = "false"){
    static if (is(T == class)) // classes are always references
        alias TP = T;
    else
        alias TP = T*;

    import std.functional : unaryFun;

    // This is a dirty hack to make variables visible
    immutable string inject_imports = "a = __a ; import dht, dhtbootserver; alias lalalal ";
    alias action_f    = unaryFun!(action,inject_imports);
    alias condition_f = unaryFun!(condition,inject_imports);
    alias reset_f     = unaryFun!(reset,inject_imports);
    alias list_t      = DoubleList!(T);	
	
    list_t* list;
    TP cursor = null;
    
    this(list_t* dlist){
        assert(dlist !is null);
	list = dlist;
    }

    void walk(uint howmany = 1){
        if(list.first is null)
	    return;
	    
        uint actions = 0;
	// If the list has changed between two walks, so that the cursor
	// now points to an element fulfilling the reset condition,
	// reset cursor to avoid endless loop

	
	if(cursor !is null && 
	    (reset_f(cursor) || (cursor.next is null && cursor.prev is null && list.num > 0)))
	    cursor = null;
	    
        TP at_start = cursor;
	do{
	    if(cursor is null){
	        cursor = list.first;
		continue; // Avoid deadlock when cursor is on 1st element
	    }
		
	    if(reset_f(cursor)){
	        cursor = null;
		continue;
	    }
	    if(condition_f(cursor)){
	        action_f(cursor);
		if(++actions >= howmany){
		    cursor = cursor.next;
		    return;
		}
	    }
	    cursor = cursor.next;
	} while(cursor !is at_start);
	return;
    }
    void flag_deleted(TP element){
        if(cursor is element)
	    cursor = cursor.next;
    }
}

// 
// A variant of Walker: Walks across a list of T, collects U items and returns them
// 
struct Collector(T, U, alias collectf, alias condition = "true", alias reset = "false"){

    static if (is(T == class)) // classes are always references
        alias TP = T;
    else
        alias TP = T*;

    import std.traits: isArray;
    static if(isArray!U)       // if U is array, such as ubyte[], Collector returns concatenation
        alias UArray = U;
    else                       // Otherwise an array of U items.
        alias UArray = U[];
    
    // This is a dirty hack to make variables visible
    immutable string inject_imports = "a = __a ; import dht, dhtbootserver; alias lalalal ";
    import std.functional : unaryFun;
    alias collect_f   = unaryFun!(collectf, inject_imports);
    alias condition_f = unaryFun!(condition, inject_imports);
    alias reset_f     = unaryFun!(reset, inject_imports);
    alias list_t      = DoubleList!(T);	
	
    list_t* list;
    TP cursor = null;
    
    this(list_t* dlist){
        assert(dlist !is null);
	list = dlist;
    }

    UArray collect(uint howmany = 1){
        if(list.first is null)
	    return [];
	    
        import std.array : appender;
        uint items = 0;
	
	// If the list has changed between two walks, so that the cursor
	// now points to an element fulfilling the reset condition,
	// reset cursor to avoid endless loop
	if(cursor !is null && 
	    (reset_f(cursor) || (cursor.next is null && cursor.prev is null && list.num > 0)))
	    cursor = null;
	    
        TP at_start = cursor;
	    
        auto bag = appender!(UArray)();	

	do{
	    if(cursor is null){
	        cursor = list.first;
		continue; // Avoid deadlock when cursor starts on 1st element
	    }
	    if(reset_f(cursor)){
	        cursor = null;
		continue;
	    }
	    if(condition_f(cursor)){
	        bag ~= collect_f(cursor);
		if(++items >= howmany){
		    cursor = cursor.next;
		    return bag.data;
		}
	    }
	    cursor = cursor.next;
	} while(cursor !is at_start);
	return bag.data;
    }
    void flag_deleted(TP element){
        if(cursor is element)
	    cursor = cursor.next;
    }
}


