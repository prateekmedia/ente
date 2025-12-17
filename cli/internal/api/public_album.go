package api

import (
	"context"
	"strconv"
)

// PublicAlbumCredentials holds the credentials for accessing a public album
type PublicAlbumCredentials struct {
	AccessToken    string
	AccessTokenJWT string // Only set if album is password protected
}

// PublicCollectionInfo is the response from /public-collection/info
type PublicCollectionInfo struct {
	Collection   Collection `json:"collection"`
	ReferralCode string     `json:"referralCode"`
}

// PublicFileDiff is the response from /public-collection/diff
type PublicFileDiff struct {
	Diff    []File `json:"diff"`
	HasMore bool   `json:"hasMore"`
}

// PasswordVerifyResponse is the response from password verification
type PasswordVerifyResponse struct {
	JWTToken string `json:"jwtToken"`
}

// GetPublicCollectionInfo fetches public collection metadata
func (c *Client) GetPublicCollectionInfo(ctx context.Context, creds PublicAlbumCredentials) (*PublicCollectionInfo, error) {
	var res PublicCollectionInfo
	r, err := c.restClient.R().
		SetContext(ctx).
		SetHeader("X-Auth-Access-Token", creds.AccessToken).
		SetResult(&res).
		Get("/public-collection/info")
	if err != nil {
		return nil, err
	}
	if r.IsError() {
		return nil, &ApiError{
			StatusCode: r.StatusCode(),
			Message:    r.String(),
		}
	}
	return &res, nil
}

// GetPublicCollectionDiff fetches files for a public collection
func (c *Client) GetPublicCollectionDiff(ctx context.Context, creds PublicAlbumCredentials, sinceTime int64) (*PublicFileDiff, error) {
	var res PublicFileDiff
	req := c.restClient.R().
		SetContext(ctx).
		SetHeader("X-Auth-Access-Token", creds.AccessToken).
		SetQueryParam("sinceTime", strconv.FormatInt(sinceTime, 10)).
		SetResult(&res)

	if creds.AccessTokenJWT != "" {
		req.SetHeader("X-Auth-Access-Token-JWT", creds.AccessTokenJWT)
	}

	r, err := req.Get("/public-collection/diff")
	if err != nil {
		return nil, err
	}
	if r.IsError() {
		return nil, &ApiError{
			StatusCode: r.StatusCode(),
			Message:    r.String(),
		}
	}
	return &res, nil
}

// VerifyPublicAlbumPassword verifies password for a protected public album
func (c *Client) VerifyPublicAlbumPassword(ctx context.Context, accessToken, passHash string) (*PasswordVerifyResponse, error) {
	var res PasswordVerifyResponse
	r, err := c.restClient.R().
		SetContext(ctx).
		SetHeader("X-Auth-Access-Token", accessToken).
		SetBody(map[string]string{"passHash": passHash}).
		SetResult(&res).
		Post("/public-collection/verify-password")
	if err != nil {
		return nil, err
	}
	if r.IsError() {
		return nil, &ApiError{
			StatusCode: r.StatusCode(),
			Message:    r.String(),
		}
	}
	return &res, nil
}

// DownloadPublicFile downloads a file from a public collection
func (c *Client) DownloadPublicFile(ctx context.Context, creds PublicAlbumCredentials, fileID int64, destPath string) error {
	req := c.downloadClient.R().
		SetContext(ctx).
		SetHeader("X-Auth-Access-Token", creds.AccessToken).
		SetOutput(destPath)

	if creds.AccessTokenJWT != "" {
		req.SetHeader("X-Auth-Access-Token-JWT", creds.AccessTokenJWT)
	}

	r, err := req.Get("https://public-albums.ente.io/download/?fileID=" + strconv.FormatInt(fileID, 10))
	if err != nil {
		return err
	}
	if r.IsError() {
		return &ApiError{
			StatusCode: r.StatusCode(),
			Message:    r.String(),
		}
	}
	return nil
}
