# Rc<RefCell<...>> Equality

```rust
use std::cell::RefCell;
use std::rc::Rc;

#[derive(PartialEq)]
struct Node {
    a: i32,
}

fn node(i: i32) -> Node {
    Node { a: i }
}

fn main() { 
    let a = Rc::new(RefCell::new(node(1)));
    assert!(a == a.clone());

    let b = Rc::new(RefCell::new(node(1)));
    assert!(a == b);

    let mut v = Vec::new();
    v.push(Rc::new(RefCell::new(node(1))));
    assert!(v.contains(&a));
}
```

