(() => {
  'use strict';

  const inputSize = 416;
  const classIds = [6, 11, 7];
  const wasmPath = 'https://cdn.jsdelivr.net/npm/@tensorflow/tfjs-tflite@0.0.1-alpha.10/wasm/';
  const modelPath = 'assets/assets/models/detector.tflite';
  const manifestPath = 'assets/assets/models/detector.json';
  let modelPromise;
  let model;
  let video;
  let stream;
  let running = false;
  let timer;
  let busy = false;
  let threshold = 0.30;
  const canvas = document.createElement('canvas');
  canvas.width = inputSize;
  canvas.height = inputSize;
  const context = canvas.getContext('2d', {willReadFrequently: true});

  function emitError(error) {
    window.dispatchEvent(new CustomEvent('pathguide-web-error', {
      detail: JSON.stringify({error: error instanceof Error ? error.message : String(error)}),
    }));
  }

  async function loadModel() {
    if (modelPromise) return modelPromise;
    modelPromise = (async () => {
      if (!window.tf || !window.tflite) {
        throw new Error('TFLite 浏览器运行库未加载，请检查网络连接');
      }
      window.tflite.setWasmPath(wasmPath);
      await window.tf.setBackend('cpu');
      await window.tf.ready();

      const manifestResponse = await fetch(manifestPath);
      if (!manifestResponse.ok) throw new Error('无法读取模型清单');
      const manifest = await manifestResponse.json();
      if (manifest.inputSize !== inputSize ||
          manifest.modelClassCount !== classIds.length ||
          manifest.modelClassIds.join(',') !== classIds.join(',')) {
        throw new Error('模型清单与浏览器解码配置不一致');
      }

      const response = await fetch(modelPath);
      if (!response.ok) throw new Error('无法读取 TFLite 模型');
      const bytes = await response.arrayBuffer();
      if (bytes.byteLength !== manifest.bytes) {
        throw new Error(`模型大小不符：${bytes.byteLength} / ${manifest.bytes}`);
      }
      const digest = await crypto.subtle.digest('SHA-256', bytes);
      const actualHash = Array.from(new Uint8Array(digest),
        value => value.toString(16).padStart(2, '0')).join('');
      if (actualHash !== manifest.sha256) throw new Error('模型 SHA-256 校验失败');

      model = await window.tflite.loadTFLiteModel(bytes, {numThreads: 1});
      const inputShape = model.inputs[0].shape;
      const outputShape = model.outputs[0].shape;
      if (inputShape.join(',') !== `1,${inputSize},${inputSize},3` ||
          outputShape.length !== 3 || outputShape[0] !== 1 ||
          Math.min(outputShape[1], outputShape[2]) !== classIds.length + 4) {
        throw new Error(`不支持的模型张量形状：${inputShape} -> ${outputShape}`);
      }
      return model;
    })().catch(error => {
      modelPromise = null;
      throw error;
    });
    return modelPromise;
  }

  function preprocess() {
    const width = video.videoWidth;
    const height = video.videoHeight;
    const scale = Math.min(inputSize / width, inputSize / height);
    const resizedWidth = Math.max(1, Math.floor(width * scale));
    const resizedHeight = Math.max(1, Math.floor(height * scale));
    const padX = Math.floor((inputSize - resizedWidth) / 2);
    const padY = Math.floor((inputSize - resizedHeight) / 2);

    context.fillStyle = 'rgb(114, 114, 114)';
    context.fillRect(0, 0, inputSize, inputSize);
    context.drawImage(video, 0, 0, width, height,
      padX, padY, resizedWidth, resizedHeight);

    const rgba = context.getImageData(0, 0, inputSize, inputSize).data;
    const rgb = new Float32Array(inputSize * inputSize * 3);
    for (let source = 0, target = 0; source < rgba.length; source += 4) {
      rgb[target++] = rgba[source] / 255;
      rgb[target++] = rgba[source + 1] / 255;
      rgb[target++] = rgba[source + 2] / 255;
    }
    return {rgb, width, height, resizedWidth, resizedHeight, padX, padY};
  }

  function intersectionOverUnion(a, b) {
    const left = Math.max(a.cx - a.w / 2, b.cx - b.w / 2);
    const top = Math.max(a.cy - a.h / 2, b.cy - b.h / 2);
    const right = Math.min(a.cx + a.w / 2, b.cx + b.w / 2);
    const bottom = Math.min(a.cy + a.h / 2, b.cy + b.h / 2);
    const intersection = Math.max(0, right - left) * Math.max(0, bottom - top);
    const union = a.w * a.h + b.w * b.h - intersection;
    return union > 0 ? intersection / union : 0;
  }

  function decode(values, shape, frame, inferenceMs) {
    const transposed = shape[1] > shape[2];
    const channels = Math.min(shape[1], shape[2]);
    const anchors = Math.max(shape[1], shape[2]);
    const stride = channels;
    const read = (anchor, channel) => transposed
      ? values[anchor * stride + channel]
      : values[channel * anchors + anchor];
    const candidates = [];

    for (let anchor = 0; anchor < anchors; anchor++) {
      let classIndex = -1;
      let score = threshold;
      for (let classId = 0; classId < classIds.length; classId++) {
        const value = read(anchor, 4 + classId);
        if (value > score) {
          score = value;
          classIndex = classId;
        }
      }
      if (classIndex < 0 || !Number.isFinite(score) || score > 1) continue;

      const cx = read(anchor, 0);
      const cy = read(anchor, 1);
      const width = read(anchor, 2);
      const height = read(anchor, 3);
      if (![cx, cy, width, height].every(Number.isFinite) || width <= 0 || height <= 0) {
        continue;
      }
      const x1 = Math.max(0, Math.min(1,
        ((cx - width / 2) * inputSize - frame.padX) / frame.resizedWidth));
      const y1 = Math.max(0, Math.min(1,
        ((cy - height / 2) * inputSize - frame.padY) / frame.resizedHeight));
      const x2 = Math.max(0, Math.min(1,
        ((cx + width / 2) * inputSize - frame.padX) / frame.resizedWidth));
      const y2 = Math.max(0, Math.min(1,
        ((cy + height / 2) * inputSize - frame.padY) / frame.resizedHeight));
      if (x2 <= x1 || y2 <= y1) continue;
      candidates.push({
        id: classIds[classIndex],
        score,
        cx: (x1 + x2) / 2,
        cy: (y1 + y2) / 2,
        w: x2 - x1,
        h: y2 - y1,
      });
    }

    candidates.sort((a, b) => b.score - a.score);
    const selected = [];
    for (const candidate of candidates) {
      if (selected.some(kept => kept.id === candidate.id &&
          intersectionOverUnion(kept, candidate) > 0.45)) continue;
      selected.push(candidate);
      if (selected.length >= 100) break;
    }
    return {detections: selected, inferenceMs, frameWidth: frame.width, frameHeight: frame.height};
  }

  async function inferFrame() {
    if (!running || busy || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA) return;
    busy = true;
    const frame = preprocess();
    const input = window.tf.tensor4d(frame.rgb, [1, inputSize, inputSize, 3]);
    let output;
    try {
      const startedAt = performance.now();
      output = model.predict(input);
      const inferenceMs = performance.now() - startedAt;
      const result = decode(output.dataSync(), model.outputs[0].shape, frame, inferenceMs);
      window.dispatchEvent(new CustomEvent('pathguide-web-frame', {
        detail: JSON.stringify(result),
      }));
    } finally {
      input.dispose();
      output?.dispose();
      busy = false;
    }
  }

  async function runLoop() {
    if (!running) return;
    try {
      await inferFrame();
    } catch (error) {
      running = false;
      emitError(error);
      return;
    }
    if (running) timer = window.setTimeout(runLoop, 150);
  }

  window.pathGuideStartCamera = async (videoElement, scoreThreshold) => {
    if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
      return '浏览器相机需要 HTTPS；请通过安全连接打开此页面';
    }
    window.pathGuideStopCamera();
    video = videoElement;
    threshold = Math.max(0, Math.min(1, scoreThreshold));
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        audio: false,
        video: {
          facingMode: {ideal: 'environment'},
          width: {ideal: 1280},
          height: {ideal: 720},
        },
      });
      video.srcObject = stream;
      await video.play();
      await loadModel();
      running = true;
      runLoop();
      return null;
    } catch (error) {
      window.pathGuideStopCamera();
      return error instanceof Error ? error.message : String(error);
    }
  };

  window.pathGuideSetThreshold = value => {
    threshold = Math.max(0, Math.min(1, Number(value)));
  };

  window.pathGuideStopCamera = () => {
    running = false;
    if (timer) window.clearTimeout(timer);
    timer = undefined;
    if (stream) stream.getTracks().forEach(track => track.stop());
    stream = undefined;
    if (video) {
      video.pause();
      video.srcObject = null;
    }
    busy = false;
  };
})();