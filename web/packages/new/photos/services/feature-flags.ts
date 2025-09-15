import { fetchFeatureFlags } from "./remote-store";

/**
 * Feature flags interface for nested collections functionality.
 */
export interface NestedCollectionsFeatureFlags {
    /** Whether nested collections are enabled for this user */
    isNestedAlbumsEnabled: boolean;
}

/**
 * All available feature flags
 */
export interface AllFeatureFlags extends NestedCollectionsFeatureFlags {
    // Add other feature flags here as needed
    isInternalUser?: boolean;
    [key: string]: boolean | string | number | undefined;
}

// Cache for feature flags to avoid repeated API calls
let cachedFeatureFlags: AllFeatureFlags | undefined;

/**
 * Fetch feature flags from remote and cache them locally.
 * 
 * @returns Promise resolving to all feature flags
 */
export const fetchAndCacheFeatureFlags = async (): Promise<AllFeatureFlags> => {
    if (cachedFeatureFlags) {
        return cachedFeatureFlags;
    }

    const response = await fetchFeatureFlags();
    const flags = await response.json();
    
    // Nested albums is enabled for internal users only for now
    const isInternalUser = flags.isInternalUser === true;
    const featureFlags: AllFeatureFlags = {
        isNestedAlbumsEnabled: isInternalUser,
        isInternalUser,
        ...flags,
    };

    cachedFeatureFlags = featureFlags;
    return featureFlags;
};

/**
 * Get cached feature flags or fetch them if not cached.
 * 
 * @returns The cached feature flags or default values if not available
 */
export const getCachedFeatureFlags = (): AllFeatureFlags => {
    return cachedFeatureFlags ?? {
        isNestedAlbumsEnabled: false,
        isInternalUser: false,
    };
};

/**
 * Check if nested albums are enabled for this user.
 * 
 * @returns true if nested albums are enabled, false otherwise
 */
export const isNestedAlbumsEnabled = (): boolean => {
    return getCachedFeatureFlags().isNestedAlbumsEnabled === true;
};

/**
 * Clear the feature flags cache. This should be called when the user logs out
 * or when we need to refetch feature flags.
 */
export const clearFeatureFlagsCache = (): void => {
    cachedFeatureFlags = undefined;
};

/**
 * Initialize feature flags by fetching them from remote.
 * This should be called early in the app lifecycle.
 */
export const initializeFeatureFlags = async (): Promise<void> => {
    try {
        await fetchAndCacheFeatureFlags();
    } catch (error) {
        console.warn("Failed to fetch feature flags:", error);
        // Continue with default values
    }
};