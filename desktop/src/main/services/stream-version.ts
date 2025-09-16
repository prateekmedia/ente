/**
 * Stream version constants for video streaming
 * Version 1: Legacy - AES-128 + CRF + Fixed IV (0x00000000)
 * Version 2: Enhanced - AES-256 + Bitrate control + Random IV per segment
 */
export enum StreamVersion {
    LEGACY = 1, // AES-128 + CRF + Fixed IV
    ENHANCED = 2, // AES-256 + Bitrate + Random IV
}

export const DEFAULT_STREAM_VERSION = StreamVersion.LEGACY;

/**
 * Get key size in bytes for the given stream version
 */
export const getKeySizeForVersion = (version: number): number => {
    return version === StreamVersion.ENHANCED ? 32 : 16; // 256-bit vs 128-bit
};

/**
 * Get version name for logging
 */
export const getVersionName = (version: number): string => {
    switch (version) {
        case StreamVersion.LEGACY:
            return "Legacy (v1)";
        case StreamVersion.ENHANCED:
            return "Enhanced (v2)";
        default:
            return "Unknown";
    }
};