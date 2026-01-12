package api

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/ente-io/museum/ente"
	model "github.com/ente-io/museum/ente/ensuchat"
	ensuchat "github.com/ente-io/museum/pkg/controller/ensuchat"
	"github.com/ente-io/museum/pkg/utils/auth"
	"github.com/ente-io/museum/pkg/utils/handler"
	"github.com/ente-io/stacktrace"
	"github.com/gin-contrib/requestid"
	"github.com/gin-gonic/gin"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/sirupsen/logrus"
)

// EnsuChatHandler expose request handlers for ensu chat endpoints.
type EnsuChatHandler struct {
	Controller *ensuchat.Controller
}

const (
	ensuChatEndpointUpsertKey     = "upsert_key"
	ensuChatEndpointGetKey        = "get_key"
	ensuChatEndpointUpsertSession = "upsert_session"
	ensuChatEndpointUpsertMessage = "upsert_message"
	ensuChatEndpointDeleteSession = "delete_session"
	ensuChatEndpointDeleteMessage = "delete_message"
	ensuChatEndpointGetDiff       = "get_diff"
)

var (
	ensuChatLatency = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "museum_ensu_chat_latency_ms",
		Help:    "Latency of ensu chat endpoints in milliseconds",
		Buckets: []float64{10, 50, 100, 200, 500, 1000, 10000, 30000, 60000, 120000, 600000},
	}, []string{"endpoint", "status"})
	ensuChatRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "museum_ensu_chat_requests_total",
		Help: "Total number of ensu chat requests by endpoint and result",
	}, []string{"endpoint", "result"})
	ensuChatDiffItems = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "museum_ensu_chat_diff_items_total",
		Help: "Number of ensu chat diff items returned",
	}, []string{"entity"})
)

func observeEnsuChatMetrics(c *gin.Context, endpoint string, startTime time.Time) {
	statusCode := c.Writer.Status()
	result := "success"
	if statusCode >= http.StatusBadRequest {
		result = "error"
	}
	ensuChatRequests.WithLabelValues(endpoint, result).Inc()
	ensuChatLatency.WithLabelValues(endpoint, strconv.Itoa(statusCode)).
		Observe(float64(time.Since(startTime).Milliseconds()))
}

func observeEnsuChatDiffMetrics(resp *model.GetDiffResponse) {
	if resp == nil {
		return
	}
	ensuChatDiffItems.WithLabelValues("sessions").Add(float64(len(resp.Sessions)))
	ensuChatDiffItems.WithLabelValues("messages").Add(float64(len(resp.Messages)))
	ensuChatDiffItems.WithLabelValues("session_tombstones").Add(float64(len(resp.Tombstones.Sessions)))
	ensuChatDiffItems.WithLabelValues("message_tombstones").Add(float64(len(resp.Tombstones.Messages)))
}

func logEnsuChatDiff(c *gin.Context, req model.GetDiffRequest, resp *model.GetDiffResponse) {
	if resp == nil {
		return
	}
	sessions := len(resp.Sessions)
	messages := len(resp.Messages)
	sessionTombstones := len(resp.Tombstones.Sessions)
	messageTombstones := len(resp.Tombstones.Messages)
	total := sessions + messages + sessionTombstones + messageTombstones
	sinceTime := int64(0)
	if req.SinceTime != nil {
		sinceTime = *req.SinceTime
	}
	logrus.WithFields(logrus.Fields{
		"req_id":             requestid.Get(c),
		"user_id":            auth.GetUserID(c.Request.Header),
		"since_time":         sinceTime,
		"limit":              req.Limit,
		"sessions":           sessions,
		"messages":           messages,
		"session_tombstones": sessionTombstones,
		"message_tombstones": messageTombstones,
		"total":              total,
		"timestamp":          resp.Timestamp,
	}).Info("ensu chat diff served")
}

// UpsertKey...
func (h *EnsuChatHandler) UpsertKey(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointUpsertKey, startTime)

	var request model.UpsertKeyRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		handler.Error(c,
			stacktrace.Propagate(ente.ErrBadRequest, fmt.Sprintf("Request binding failed %s", err)))
		return
	}
	resp, err := h.Controller.UpsertKey(c, request)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to upsert ensu chat key"))
		return
	}
	c.JSON(http.StatusOK, resp)
}

// GetKey...
func (h *EnsuChatHandler) GetKey(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointGetKey, startTime)

	resp, err := h.Controller.GetKey(c)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to get ensu chat key"))
		return
	}
	c.JSON(http.StatusOK, resp)
}

// UpsertSession...
func (h *EnsuChatHandler) UpsertSession(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointUpsertSession, startTime)

	var request model.UpsertSessionRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		handler.Error(c,
			stacktrace.Propagate(ente.ErrBadRequest, fmt.Sprintf("Request binding failed %s", err)))
		return
	}
	resp, err := h.Controller.UpsertSession(c, request)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to upsert ensu chat session"))
		return
	}
	c.JSON(http.StatusOK, resp)
}

// UpsertMessage...
func (h *EnsuChatHandler) UpsertMessage(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointUpsertMessage, startTime)

	var request model.UpsertMessageRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		handler.Error(c,
			stacktrace.Propagate(ente.ErrBadRequest, fmt.Sprintf("Request binding failed %s", err)))
		return
	}
	resp, err := h.Controller.UpsertMessage(c, request)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to upsert ensu chat message"))
		return
	}
	c.JSON(http.StatusOK, resp)
}

// DeleteSession...
func (h *EnsuChatHandler) DeleteSession(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointDeleteSession, startTime)

	sessionUUID := c.Query("id")
	if sessionUUID == "" {
		handler.Error(c, stacktrace.Propagate(ente.ErrBadRequest, "Missing session id"))
		return
	}
	resp, err := h.Controller.DeleteSession(c, sessionUUID)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to delete ensu chat session"))
		return
	}
	c.JSON(http.StatusOK, resp)
}

// DeleteMessage...
func (h *EnsuChatHandler) DeleteMessage(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointDeleteMessage, startTime)

	messageUUID := c.Query("id")
	if messageUUID == "" {
		handler.Error(c, stacktrace.Propagate(ente.ErrBadRequest, "Missing message id"))
		return
	}
	resp, err := h.Controller.DeleteMessage(c, messageUUID)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to delete ensu chat message"))
		return
	}
	c.JSON(http.StatusOK, resp)
}

// GetDiff...
func (h *EnsuChatHandler) GetDiff(c *gin.Context) {
	startTime := time.Now()
	defer observeEnsuChatMetrics(c, ensuChatEndpointGetDiff, startTime)

	var request model.GetDiffRequest
	if err := c.ShouldBindQuery(&request); err != nil {
		handler.Error(c,
			stacktrace.Propagate(ente.ErrBadRequest, fmt.Sprintf("Request binding failed %s", err)))
		return
	}
	if request.Limit <= 0 {
		request.Limit = 500
	}
	resp, err := h.Controller.GetDiff(c, request)
	if err != nil {
		handler.Error(c, stacktrace.Propagate(err, "Failed to fetch ensu chat diff"))
		return
	}
	observeEnsuChatDiffMetrics(resp)
	logEnsuChatDiff(c, request, resp)
	c.JSON(http.StatusOK, resp)
}
