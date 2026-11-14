// How a request finds its routes.
//
// The routes live in a tree of path segments, so that looking up a path costs a few hash lookups
// instead of a comparison with every route there is:
//
//    /api/users/:id   root -> "api" -> "users" -> (param)       the route ends there: `exact`
//    /static/*        root -> "static"                          the route is in `wild`: it matches /static and everything below
//    *                root                                      `wild` of the root
//
// A path can match several routes (middleware, then the handler). They all come out of router_find()
// in the order they were added, which is the order they run in: the same as when every request
// was compared to the list of routes one by one.

Route_Node :: struct {
  children : Table(string, *Route_Node); // static segments
  param    : *Route_Node;                // a :name segment
  exact    : [..] s32;                   // indices into `middlewares` of the routes that end at this node
  wild     : [..] s32;                   // ... and the ones that end with * here
}
route_root: Route_Node;

// routes_lock must be held. `pattern` is a normalized route path, `index` is the place of the route in `middlewares`.
router_insert :: (index: s32, pattern: string) {
  node := *route_root;
  if pattern == "*" { array_add(*node.wild, index); return; }

  rest := pattern;
  while true {
    segment, has_segment := next_segment(*rest);
    if !has_segment { array_add(*node.exact, index); return; }
    if segment == "*" { array_add(*node.wild, index); return; } // what follows a * does not matter, as in match_route

    if segment[0] == #char ":" {
      if !node.param  node.param = New(Route_Node);
      node = node.param;
    } else {
      found, child := table_find(*node.children, segment);
      if !found {
        child = New(Route_Node);
        table_add(*node.children, copy_string(segment), child); // the key outlives the pattern
      }
      node = child;
    }
  }
}

router_collect :: (node: *Route_Node, path: string, out: *[..] s32) {
  rest := path;
  for node.wild  array_add(out, it); // /api/* matches /api as well, so this comes before looking at the next segment

  segment, has_segment := next_segment(*rest);
  if !has_segment {
    for node.exact  array_add(out, it);
    return;
  }

  found, child := table_find(*node.children, segment);
  if found  router_collect(child, rest, out);
  if node.param  router_collect(node.param, rest, out);
}

// The routes that match a normalized path, in the order they were added. The method is not looked at here.
// The result is in temporary storage.
router_find :: (path: string) -> [] Middleware {
  push_allocator(temp);

  indices: [..] s32;
  lock(*routes_lock);
  defer unlock(*routes_lock);
  router_collect(*route_root, path, *indices);

  // Usually one to five of them: insertion sort. The branches of the tree each give their own
  // routes in order, but not the routes of different branches.
  for i: 1 .. indices.count - 1 {
    value := indices[i];
    j := i - 1;
    while j >= 0 && indices[j] > value {
      indices[j + 1] = indices[j];
      j -= 1;
    }
    indices[j + 1] = value;
  }

  result: [..] Middleware;
  array_reserve(*result, indices.count);
  for indices  array_add(*result, middlewares[it]);
  return result;
}
