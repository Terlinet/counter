// mediapipe_bridge.js
let objectDetector;

window.initObjectDetector = async function() {
    try {
        const vision = await FilesetResolver.forVisionTasks(
            "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.17/wasm"
        );

        objectDetector = await ObjectDetector.createFromOptions(vision, {
            baseOptions: {
                modelAssetPath: "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float16/1/efficientdet_lite0.tflite",
                delegate: "GPU"
            },
            runningMode: "VIDEO",
            scoreThreshold: 0.3
        });

        console.log("🎯 MediaPipe Object Detector Online");
        window.dispatchEvent(new Event('mediapipe-ready'));
    } catch (e) {
        console.warn("⚠️ GPU fail, trying CPU...", e);
        try {
            const vision = await FilesetResolver.forVisionTasks("https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.17/wasm");
            objectDetector = await ObjectDetector.createFromOptions(vision, {
                baseOptions: {
                    modelAssetPath: "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float16/1/efficientdet_lite0.tflite",
                    delegate: "CPU"
                },
                runningMode: "VIDEO",
                scoreThreshold: 0.3
            });
            window.dispatchEvent(new Event('mediapipe-ready'));
        } catch (err) {
            console.error("❌ Fatal IA Error:", err);
            window.dispatchEvent(new Event('mediapipe-error'));
        }
    }
};

// Função que recebe o elemento de vídeo diretamente do Dart
window.runObjectDetection = function(videoElement) {
    if (!objectDetector || !videoElement || videoElement.readyState < 2) return [];

    try {
        const result = objectDetector.detectForVideo(videoElement, performance.now());
        const allowed = ['person', 'car', 'bicycle', 'motorcycle'];

        return result.detections
            .filter(d => d.categories[0].score > 0.3 && allowed.includes(d.categories[0].categoryName))
            .map(d => ({
                class: d.categories[0].categoryName,
                score: d.categories[0].score,
                bbox: [
                    d.boundingBox.originX,
                    d.boundingBox.originY,
                    d.boundingBox.width,
                    d.boundingBox.height
                ]
            }));
    } catch (err) {
        return [];
    }
};
