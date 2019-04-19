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
