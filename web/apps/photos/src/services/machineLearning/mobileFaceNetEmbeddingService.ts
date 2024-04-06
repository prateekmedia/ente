import { MOBILEFACENET_FACE_SIZE } from "constants/mlConfig";
import PQueue from "p-queue";
import {
    FaceEmbedding,
    FaceEmbeddingMethod,
    FaceEmbeddingService,
    Versioned,
} from "types/machineLearning";

import * as ort from "onnxruntime-web";
import { env } from "onnxruntime-web";
import {
    clamp,
    getPixelBilinear,
    normalizePixelBetweenMinus1And1,
} from "utils/image";

env.wasm.wasmPaths = "/js/onnx/";
class MobileFaceNetEmbeddingService implements FaceEmbeddingService {
    private onnxInferenceSession?: ort.InferenceSession;
    public method: Versioned<FaceEmbeddingMethod>;
    public faceSize: number;

    private serialQueue: PQueue;

    public constructor(faceSize: number = MOBILEFACENET_FACE_SIZE) {
        this.method = {
            value: "MobileFaceNet",
            version: 2,
        };
        this.faceSize = faceSize;
        // TODO: set timeout
        this.serialQueue = new PQueue({ concurrency: 1 });
    }

    private async initOnnx() {
        console.log("start ort mobilefacenet");
        this.onnxInferenceSession = await ort.InferenceSession.create(
            "/models/mobilefacenet/mobilefacenet_opset15.onnx",
        );
        const faceBatchSize = 1;
        const data = new Float32Array(
            faceBatchSize * 3 * this.faceSize * this.faceSize,
        );
        const inputTensor = new ort.Tensor("float32", data, [
            faceBatchSize,
            this.faceSize,
            this.faceSize,
            3,
        ]);
        const feeds: Record<string, ort.Tensor> = {};
        const name = this.onnxInferenceSession.inputNames[0];
        feeds[name] = inputTensor;
        await this.onnxInferenceSession.run(feeds);
        console.log("start end mobilefacenet");
    }

    private async getOnnxInferenceSession() {
        if (!this.onnxInferenceSession) {
            await this.initOnnx();
        }
        return this.onnxInferenceSession;
    }

    private preprocessImageBitmapToFloat32(
        imageBitmap: ImageBitmap,
        requiredWidth: number = this.faceSize,
        requiredHeight: number = this.faceSize,
        maintainAspectRatio: boolean = true,
        normFunction: (
            pixelValue: number,
        ) => number = normalizePixelBetweenMinus1And1,
    ) {
        // Create an OffscreenCanvas and set its size
        const offscreenCanvas = new OffscreenCanvas(
            imageBitmap.width,
            imageBitmap.height,
        );
        const ctx = offscreenCanvas.getContext("2d");
        ctx.drawImage(imageBitmap, 0, 0, imageBitmap.width, imageBitmap.height);
        const imageData = ctx.getImageData(
            0,
            0,
            imageBitmap.width,
            imageBitmap.height,
        );
        const pixelData = imageData.data;

        let scaleW = requiredWidth / imageBitmap.width;
        let scaleH = requiredHeight / imageBitmap.height;
        if (maintainAspectRatio) {
            const scale = Math.min(
                requiredWidth / imageBitmap.width,
                requiredHeight / imageBitmap.height,
            );
            scaleW = scale;
            scaleH = scale;
        }
        const scaledWidth = clamp(
            Math.round(imageBitmap.width * scaleW),
            0,
            requiredWidth,
        );
        const scaledHeight = clamp(
            Math.round(imageBitmap.height * scaleH),
            0,
            requiredHeight,
        );

        const processedImage = new Float32Array(
            1 * requiredWidth * requiredHeight * 3,
        );

        // Populate the Float32Array with normalized pixel values
        for (let h = 0; h < requiredHeight; h++) {
            for (let w = 0; w < requiredWidth; w++) {
                let pixel: {
                    r: number;
                    g: number;
                    b: number;
                };
                if (w >= scaledWidth || h >= scaledHeight) {
                    pixel = { r: 114, g: 114, b: 114 };
                } else {
                    pixel = getPixelBilinear(
                        w / scaleW,
                        h / scaleH,
                        pixelData,
                        imageBitmap.width,
                        imageBitmap.height,
                    );
                }
                const pixelIndex = 3 * (h * requiredWidth + w);
                processedImage[pixelIndex] = normFunction(pixel.r);
                processedImage[pixelIndex + 1] = normFunction(pixel.g);
                processedImage[pixelIndex + 2] = normFunction(pixel.b);
            }
        }

        return processedImage;
    }

    // Do not use this, use getFaceEmbedding which calls this through serialqueue
    private async getFaceEmbeddingNoQueue(
        faceImage: ImageBitmap,
    ): Promise<FaceEmbedding> {
        const data = this.preprocessImageBitmapToFloat32(faceImage);
        const inputTensor = new ort.Tensor("float32", data, [
            1,
            this.faceSize,
            this.faceSize,
            3,
        ]);
        const feeds: Record<string, ort.Tensor> = {};
        feeds["img_inputs"] = inputTensor;
        const inferenceSession = await this.getOnnxInferenceSession();
        const runout: ort.InferenceSession.OnnxValueMapType =
            await inferenceSession.run(feeds);
        const test = runout.embeddings;
        // const test2 = test.cpuData;
        const outputData = runout.embeddings["cpuData"] as Float32Array;
        // const outputData = runout.embeddings as Float32Array;
        return new Float32Array(outputData);
    }

    // TODO: TFLiteModel seems to not work concurrenly,
    // remove serialqueue if that is not the case
    private async getFaceEmbedding(
        faceImage: ImageBitmap,
    ): Promise<FaceEmbedding> {
        // @ts-expect-error "TODO: Fix ML related type errors"
        return this.serialQueue.add(() =>
            this.getFaceEmbeddingNoQueue(faceImage),
        );
    }

    public async getFaceEmbeddings(
        faceImages: Array<ImageBitmap>,
    ): Promise<Array<FaceEmbedding>> {
        return Promise.all(
            faceImages.map((faceImage) => this.getFaceEmbedding(faceImage)),
        );
    }

    public async dispose() {
        const inferenceSession = await this.getOnnxInferenceSession();
        inferenceSession?.release();
        this.onnxInferenceSession = undefined;
    }
}

export default new MobileFaceNetEmbeddingService();
