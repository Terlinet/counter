// mediapipe_bridge.js
let objectDetector;

window.initObjectDetector = async function() {
    try {
        const vision = await FilesetResolver.forVisionTasks(
            "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision/wasm"
        );

        const options = {
            baseOptions: {
                modelAssetPath: "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float16/1/efficientdet_lite0.tflite",
                delegate: "GPU"
            },
            runningMode: "VIDEO",
            scoreThreshold: 0.3
        };

        try {
            objectDetector = await ObjectDetector.createFromOptions(vision, options);
            console.log("🎯 MediaPipe initialized: GPU");
        } catch (e) {
            console.warn("⚠️ GPU failed, trying CPU...");
            options.baseOptions.delegate = "CPU";
            objectDetector = await ObjectDetector.createFromOptions(vision, options);
            console.log("🎯 MediaPipe initialized: CPU");
        }

        window.dispatchEvent(new Event('mediapipe-ready'));
    } catch (e) {
        console.error("❌ Fatal IA Error:", e);
        window.dispatchEvent(new Event('mediapipe-error'));
    }
};

window.runObjectDetection = function(videoID) {
    if (!objectDetector) return [];
    const video = document.getElementById(videoID);
    if (!video || video.readyState < 2) return [];

    try {
        const result = objectDetector.detectForVideo(video, performance.now());
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
