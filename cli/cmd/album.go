package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var albumCmd = &cobra.Command{
	Use:   "album",
	Short: "Album operations",
}

var randomAlbumCmd = &cobra.Command{
	Use:   "random",
	Short: "Download a random file from an album (requires login)",
	RunE: func(cmd *cobra.Command, args []string) error {
		recoverWithLog()
		albumName, _ := cmd.Flags().GetString("album")
		outputPath, _ := cmd.Flags().GetString("output")
		fileType, _ := cmd.Flags().GetString("type")
		if albumName == "" {
			return fmt.Errorf("album name is required, use --album")
		}
		return ctrl.DownloadRandomFromAlbum(albumName, outputPath, fileType)
	},
}

var randomLinkCmd = &cobra.Command{
	Use:   "random-link",
	Short: "Download a random file from a public album link (no login required)",
	Long: `Download a random file from a public album using its share link.
	
Example:
  ente album random-link --url "https://albums.ente.io/?t=TOKEN#KEY"
  ente album random-link --url "https://albums.ente.io/?t=TOKEN#KEY" --type image
  ente album random-link --url "https://albums.ente.io/?t=TOKEN#KEY" --password "secret"`,
	RunE: func(cmd *cobra.Command, args []string) error {
		recoverWithLog()
		albumURL, _ := cmd.Flags().GetString("url")
		outputPath, _ := cmd.Flags().GetString("output")
		fileType, _ := cmd.Flags().GetString("type")
		password, _ := cmd.Flags().GetString("password")
		if albumURL == "" {
			return fmt.Errorf("album URL is required, use --url")
		}
		return ctrl.DownloadRandomFromPublicAlbum(albumURL, outputPath, fileType, password)
	},
}

func init() {
	rootCmd.AddCommand(albumCmd)

	// random subcommand (requires login)
	randomAlbumCmd.Flags().StringP("album", "a", "", "Album name (required)")
	randomAlbumCmd.Flags().StringP("output", "o", ".", "Output path (file or directory)")
	randomAlbumCmd.Flags().StringP("type", "t", "", "Filter: image|video|live or extension like .jpg, .png, .mp4")
	_ = randomAlbumCmd.MarkFlagRequired("album")

	// random-link subcommand (public albums, no login)
	randomLinkCmd.Flags().StringP("url", "u", "", "Public album URL (required)")
	randomLinkCmd.Flags().StringP("output", "o", ".", "Output path (file or directory)")
	randomLinkCmd.Flags().StringP("type", "t", "", "Filter: image|video|live or extension like .jpg, .png, .mp4")
	randomLinkCmd.Flags().StringP("password", "p", "", "Password for protected albums")
	_ = randomLinkCmd.MarkFlagRequired("url")

	albumCmd.AddCommand(randomAlbumCmd)
	albumCmd.AddCommand(randomLinkCmd)
}
