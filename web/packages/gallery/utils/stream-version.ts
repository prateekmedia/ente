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
 * Check if a version is valid
 */
export const isValidVersion = (version: number): boolean => {
    return version === StreamVersion.LEGACY || version === StreamVersion.ENHANCED;
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

/**
 * Determine key size based on stream version
 */
export const getKeySizeForVersion = (version: number): number => {
    return version === StreamVersion.ENHANCED ? 32 : 16; // 256-bit vs 128-bit
};