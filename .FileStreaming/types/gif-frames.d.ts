declare module 'gif-frames' {
    interface GifFrame {
        getImage(): Promise<NodeJS.ReadableStream>;
    }

    interface GifFramesOptions {
        url: string;
        frames: string;
        outputType: string;
        cumulative?: boolean;
    }

    function gifFrames(options: GifFramesOptions): Promise<GifFrame[]>;

    export = gifFrames;
}
