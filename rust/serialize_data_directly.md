# Serialize Data Directly


```rust

#[repr(C)]
struct Unit {
	hp: u32,
	atk: u16,
}

unsafe {
	let mut buffer: [u8; 64] = mem::uninitialized();

	let mut m = (&mut buffer) as *mut _ as *mut Unit
	(*m).hp = 10;
	(*m).atk = 1000;

	assert_eq!(buffer[..mem::size_of::<Unit>()], [10, 0, 0, 0, 232, 3, 0, 0]);
}


```


```rust
#[repr(C)]
struct Unit {
	hp: u32,
	atk: u16,
}

unsafe {
	let mut buffer: [u8; 64] = mem::uninitialized();
	let mut p = buffer.as_mut_ptr();

	let m = p as *mut Unit;
	(*m).hp = 10;
	(*m).atk = 1000;

	p = p.offset(mem::size_of::<Unit>() as isize);

	let n = p as *mut Unit;
	(*m).hp = 20;
	(*m).atk = 2000;

	assert_eq!(
		buffer[..mem::size_of::<User>() * 2],
		[10, 0, 0, 0, 232, 3, 0, 0, 20, 0, 0, 0, 208, 7, 0, 0]
	);
}
```
