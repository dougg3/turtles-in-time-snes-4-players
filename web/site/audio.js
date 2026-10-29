// AudioWorklet: plays the emulator's stereo int16 ring buffer (shared wasm memory)
class SnesAudio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.port.onmessage = (e) => {
      const d = e.data;
      this.samples = new Int16Array(d.buffer, d.audioPtr, d.capacity * 2);
      this.u32 = new Uint32Array(d.buffer);
      this.i32 = new Int32Array(d.buffer);   // Atomics.notify only takes Int32Array
      this.wIdx = d.wPtr >> 2;
      this.rIdx = d.rPtr >> 2;
      this.mask = d.capacity - 1;
      this.underIdx = d.underrunsPtr >> 2;
    };
  }

  process(inputs, outputs) {
    const [left, right] = outputs[0];
    if (!this.samples) return true;
    let r = Atomics.load(this.u32, this.rIdx);
    const w = Atomics.load(this.u32, this.wIdx);
    let starved = false;
    for (let i = 0; i < left.length; i++) {
      if (r !== w) {
        const p = (r & this.mask) * 2;
        left[i] = this.samples[p] / 32768;
        right[i] = this.samples[p + 1] / 32768;
        r = (r + 1) >>> 0;
        this.started = true;
      } else {
        left[i] = right[i] = 0;
        starved = true;
      }
    }
    Atomics.store(this.u32, this.rIdx, r);
    Atomics.notify(this.i32, this.rIdx);   // wakes the emulator thread waiting for room in the queue
    // a dropout: the emulator didn't deliver in time (counted once per 128-sample block)
    if (starved && this.started) Atomics.add(this.u32, this.underIdx, 1);
    return true;
  }
}
registerProcessor('snes-audio', SnesAudio);
