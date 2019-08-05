
# Permutation


```rust
pub fn next_permutation<T: std::cmp::Ord + std::clone::Clone>(mut v: Vec<T>) -> Vec<T> {
    if v.len() < 2 {
        return v;
    }
    let mut pivot = 1;
    while v[pivot-1] <= v[pivot] {
        pivot += 1;
    }

    let mut min_idx = None;
    for i in 0..pivot {
        if v[pivot] < v[i] {
            if min_idx == None || v[i] < v[min_idx.unwrap()] {
                min_idx = Some(i);
            }
        }
    }

    v.swap(min_idx.unwrap(), pivot);

    let mut ret = Vec::new();
    for i in 0..pivot {
        ret.push(v[i].clone());
    }
    ret.sort_by(|a,b| b.cmp(a));
    for i in pivot..v.len() {
        ret.push(v[i].clone());
    }
    ret
}

#[test]
fn test_permutation() {
    assert_eq!(next_permutation(vec![3,2,1]), vec![2,3,1]);
    assert_eq!(next_permutation(vec![0,3,3,5,2,1,0]), vec![5,3,2,0,3,1,0]);
}

```
