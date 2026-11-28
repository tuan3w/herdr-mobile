//! Python's `random.Random(int)`: MT19937 seeded the way CPython seeds it
//! (`init_by_array` over the 32-bit words of the seed), with `random()` and
//! `randrange(n)` as CPython 3 computes them. `fake-herdr` uses it so its
//! pane text is the same bytes the python stand-in produced.

const N: usize = 624;
const M: usize = 397;

pub struct Random {
    state: [u32; N],
    index: usize,
}

impl Random {
    pub fn new(seed: u64) -> Self {
        let mut r = Random {
            state: [0; N],
            index: N,
        };
        let key: Vec<u32> = if seed >> 32 == 0 {
            vec![seed as u32]
        } else {
            vec![seed as u32, (seed >> 32) as u32]
        };
        r.init_genrand(19_650_218);
        let (mut i, mut j) = (1usize, 0usize);
        for _ in 0..N.max(key.len()) {
            let prev = r.state[i - 1] ^ (r.state[i - 1] >> 30);
            r.state[i] = (r.state[i] ^ prev.wrapping_mul(1_664_525))
                .wrapping_add(key[j])
                .wrapping_add(j as u32);
            i += 1;
            j += 1;
            if i >= N {
                r.state[0] = r.state[N - 1];
                i = 1;
            }
            if j >= key.len() {
                j = 0;
            }
        }
        for _ in 0..N - 1 {
            let prev = r.state[i - 1] ^ (r.state[i - 1] >> 30);
            r.state[i] = (r.state[i] ^ prev.wrapping_mul(1_566_083_941)).wrapping_sub(i as u32);
            i += 1;
            if i >= N {
                r.state[0] = r.state[N - 1];
                i = 1;
            }
        }
        r.state[0] = 0x8000_0000;
        r
    }

    fn init_genrand(&mut self, s: u32) {
        self.state[0] = s;
        for i in 1..N {
            let prev = self.state[i - 1] ^ (self.state[i - 1] >> 30);
            self.state[i] = prev.wrapping_mul(1_812_433_253).wrapping_add(i as u32);
        }
    }

    fn next_u32(&mut self) -> u32 {
        if self.index >= N {
            for k in 0..N {
                let y = (self.state[k] & 0x8000_0000) | (self.state[(k + 1) % N] & 0x7fff_ffff);
                let mut v = self.state[(k + M) % N] ^ (y >> 1);
                if y & 1 != 0 {
                    v ^= 0x9908_b0df;
                }
                self.state[k] = v;
            }
            self.index = 0;
        }
        let mut y = self.state[self.index];
        self.index += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c_5680;
        y ^= (y << 15) & 0xefc6_0000;
        y ^= y >> 18;
        y
    }

    /// `random.random()`: a float in [0, 1) from 53 bits.
    pub fn random(&mut self) -> f64 {
        let a = f64::from(self.next_u32() >> 5);
        let b = f64::from(self.next_u32() >> 6);
        (a * 67_108_864.0 + b) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// `random.randrange(n)` for `0 < n < 2**32`: `getrandbits(n.bit_length())`
    /// until the draw is below `n`.
    pub fn randrange(&mut self, n: u32) -> u32 {
        if n == 0 {
            return 0;
        }
        let k = 32 - n.leading_zeros();
        loop {
            let r = self.next_u32() >> (32 - k);
            if r < n {
                return r;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_cpython() {
        // random.Random(42).random() == 0.6394267984578837
        assert_eq!(Random::new(42).random(), 0.639_426_798_457_883_7);
        // random.Random(0).random() == 0.8444218515250481
        assert_eq!(Random::new(0).random(), 0.844_421_851_525_048_1);
        // [Random(1).randrange(6) for _ in range(5)] == [1, 4, 0, 2, 0]
        let mut r = Random::new(1);
        let got: Vec<u32> = (0..5).map(|_| r.randrange(6)).collect();
        assert_eq!(got, [1, 4, 0, 2, 0]);
        // r = Random(39 * 1000003 + 1300): three randrange(256), then random()
        let mut r = Random::new(39 * 1_000_003 + 1300);
        let got: Vec<u32> = (0..3).map(|_| r.randrange(256)).collect();
        assert_eq!(got, [29, 105, 18]);
        assert_eq!(r.random(), 0.766_852_349_944_631_7);
    }
}
