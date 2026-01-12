package ensuchat

import "database/sql"

// Repository defines the methods for inserting, updating and retrieving
// ensu chat related keys and entities from the underlying repository
type Repository struct {
	DB *sql.DB
}
