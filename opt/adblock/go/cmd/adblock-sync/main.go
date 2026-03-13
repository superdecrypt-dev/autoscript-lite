package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	defaultEnvFile         = "/etc/autoscript/ssh-adblock/config.env"
	defaultStateRoot       = "/opt/quota/ssh"
	defaultBlocklistFile   = "/etc/autoscript/ssh-adblock/blocked.domains"
	defaultURLsFile        = "/etc/autoscript/ssh-adblock/source.urls"
	defaultMergedFile      = "/etc/autoscript/ssh-adblock/merged.domains"
	defaultRenderedFile    = "/etc/autoscript/ssh-adblock/blocklist.generated.conf"
	defaultCustomDat       = "/usr/local/share/xray/custom.dat"
	defaultXrayRoutingFile = "/usr/local/etc/xray/conf.d/30-routing.json"
	defaultXrayAdblockRule = "ext:custom.dat:adblock"
	defaultNFTTable        = "autoscript_ssh_adblock"
	defaultDNSPort         = 5353
	defaultDNSService      = "ssh-adblock-dns.service"
	defaultSyncService     = "adblock-sync.service"
	defaultXrayService     = "xray"
	defaultHTTPTimeout     = 45 * time.Second
)

const (
	keyDirty             = "AUTOSCRIPT_ADBLOCK_DIRTY"
	keyLastUpdate        = "AUTOSCRIPT_ADBLOCK_LAST_UPDATE"
	keyMergedFile        = "AUTOSCRIPT_ADBLOCK_MERGED_FILE"
	keyCustomDat         = "AUTOSCRIPT_ADBLOCK_CUSTOM_DAT"
	keyXrayService       = "AUTOSCRIPT_ADBLOCK_XRAY_SERVICE"
	keyAutoUpdateEnabled = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_ENABLED"
	keyAutoUpdateService = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_SERVICE"
	keyAutoUpdateTimer   = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_TIMER"
	keyAutoUpdateDays    = "AUTOSCRIPT_ADBLOCK_AUTO_UPDATE_DAYS"
)

var sshUserRe = regexp.MustCompile(`^([a-z_][a-z0-9_-]{0,31})@ssh\.json$`)

type options struct {
	apply               bool
	update              bool
	reloadXray          bool
	reloadXrayIfEnabled bool
	status              bool
	showUsers           bool
	envFile             string
}

type config struct {
	Enabled           bool
	Dirty             bool
	LastUpdate        string
	StateRoot         string
	BlocklistFile     string
	URLsFile          string
	MergedFile        string
	RenderedFile      string
	CustomDat         string
	NFTTable          string
	DNSPort           int
	DNSService        string
	SyncService       string
	XrayService       string
	AutoUpdateEnabled bool
	AutoUpdateService string
	AutoUpdateTimer   string
	AutoUpdateDays    int
	EnvFile           string
	SourceURLs        []string
}

type managedUser struct {
	Username string
	UID      int
}

func main() {
	opts := parseOptions()
	cfg := loadConfig(opts.envFile)

	switch {
	case opts.showUsers:
		printUsers(cfg)
		return
	case opts.status:
		printStatus(cfg)
		return
	}

	reloadXray := opts.reloadXray
	if opts.reloadXrayIfEnabled && xrayAdblockEnabled() {
		reloadXray = true
	}

	users, blocklist, err := applyRuntime(cfg, opts.update, reloadXray)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	if opts.apply || opts.update || (!opts.status && !opts.showUsers) {
		fmt.Fprintf(
			os.Stderr,
			"adblock-sync: enabled=%d users=%d blocklist=%d urls=%d\n",
			boolInt(cfg.Enabled),
			len(users),
			len(blocklist),
			len(cfg.SourceURLs),
		)
	}
}

func parseOptions() options {
	var opts options
	flag.BoolVar(&opts.apply, "apply", false, "Apply current runtime state")
	flag.BoolVar(&opts.update, "update", false, "Refresh sources, rebuild artifacts, and apply runtime state")
	flag.BoolVar(&opts.reloadXray, "reload-xray", false, "Reload xray service when custom.dat changes")
	flag.BoolVar(&opts.reloadXrayIfEnabled, "reload-xray-if-enabled", false, "Reload xray only when the Xray adblock rule is currently enabled")
	flag.BoolVar(&opts.status, "status", false, "Print runtime status")
	flag.BoolVar(&opts.showUsers, "show-users", false, "Print bound SSH users")
	flag.StringVar(&opts.envFile, "env-file", defaultEnvFile, "Path to adblock env file")
	flag.Parse()
	return opts
}

func loadConfig(envFile string) config {
	env := parseEnvFile(envFile)
	cfg := config{
		Enabled:           toBool(env["SSH_DNS_ADBLOCK_ENABLED"]),
		Dirty:             toBool(env[keyDirty]),
		LastUpdate:        strings.TrimSpace(env[keyLastUpdate]),
		StateRoot:         orDefault(env["SSH_DNS_ADBLOCK_STATE_ROOT"], defaultStateRoot),
		BlocklistFile:     orDefault(env["SSH_DNS_ADBLOCK_BLOCKLIST_FILE"], defaultBlocklistFile),
		URLsFile:          orDefault(env["SSH_DNS_ADBLOCK_URLS_FILE"], defaultURLsFile),
		MergedFile:        orDefault(env[keyMergedFile], defaultMergedFile),
		RenderedFile:      orDefault(env["SSH_DNS_ADBLOCK_RENDERED_FILE"], defaultRenderedFile),
		CustomDat:         orDefault(env[keyCustomDat], defaultCustomDat),
		NFTTable:          orDefault(env["SSH_DNS_ADBLOCK_NFT_TABLE"], defaultNFTTable),
		DNSPort:           max(1, toInt(env["SSH_DNS_ADBLOCK_PORT"], defaultDNSPort)),
		DNSService:        orDefault(env["SSH_DNS_ADBLOCK_SERVICE"], defaultDNSService),
		SyncService:       orDefault(env["SSH_DNS_ADBLOCK_SYNC_SERVICE"], defaultSyncService),
		XrayService:       orDefault(env[keyXrayService], defaultXrayService),
		AutoUpdateEnabled: toBool(env[keyAutoUpdateEnabled]),
		AutoUpdateService: orDefault(env[keyAutoUpdateService], "adblock-update.service"),
		AutoUpdateTimer:   orDefault(env[keyAutoUpdateTimer], "adblock-update.timer"),
		AutoUpdateDays:    max(1, toInt(env[keyAutoUpdateDays], 1)),
		EnvFile:           envFile,
	}
	cfg.SourceURLs = readURLsFile(cfg.URLsFile)
	return cfg
}

func parseEnvFile(path string) map[string]string {
	out := make(map[string]string)
	file, err := os.Open(path)
	if err != nil {
		return out
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		out[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return out
}

func toBool(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on", "y":
		return true
	default:
		return false
	}
}

func toInt(value string, fallback int) int {
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return fallback
	}
	return n
}

func orDefault(value, fallback string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return fallback
	}
	return value
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func serviceState(name string) string {
	name = strings.TrimSpace(name)
	if name == "" {
		return "missing"
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		return "missing"
	}
	cmd := exec.Command("systemctl", "is-active", name)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Run(); err == nil {
		return "active"
	}
	return "inactive"
}

func serviceStart(name string) bool {
	return runQuietCommand("systemctl", "start", strings.TrimSpace(name)) == nil
}

func serviceRestart(name string) bool {
	return runQuietCommand("systemctl", "restart", strings.TrimSpace(name)) == nil
}

func tableExists(tableName string) bool {
	if _, err := exec.LookPath("nft"); err != nil {
		return false
	}
	cmd := exec.Command("nft", "list", "table", "inet", strings.TrimSpace(tableName))
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run() == nil
}

func listManagedUsers(stateRoot string) []managedUser {
	passwd := loadPasswdUIDs()
	rootEntries, err := os.ReadDir(stateRoot)
	if err != nil {
		return nil
	}
	var users []managedUser
	seenUIDs := make(map[int]struct{})
	for _, entry := range rootEntries {
		if entry.IsDir() {
			continue
		}
		match := sshUserRe.FindStringSubmatch(entry.Name())
		if match == nil {
			continue
		}
		username := match[1]
		uid, ok := passwd[username]
		if !ok || uid <= 0 {
			continue
		}
		if _, exists := seenUIDs[uid]; exists {
			continue
		}
		seenUIDs[uid] = struct{}{}
		users = append(users, managedUser{Username: username, UID: uid})
	}
	sort.Slice(users, func(i, j int) bool {
		return users[i].Username < users[j].Username
	})
	return users
}

func loadPasswdUIDs() map[string]int {
	out := make(map[string]int)
	file, err := os.Open("/etc/passwd")
	if err != nil {
		return out
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Split(line, ":")
		if len(fields) < 3 {
			continue
		}
		uid, err := strconv.Atoi(strings.TrimSpace(fields[2]))
		if err != nil {
			continue
		}
		out[fields[0]] = uid
	}
	return out
}

func normalizeDomain(value string) string {
	domain := strings.TrimSuffix(strings.ToLower(strings.TrimSpace(value)), ".")
	switch {
	case domain == "":
		return ""
	case strings.HasPrefix(domain, "#"):
		return ""
	case strings.Contains(domain, " "):
		return ""
	case strings.Contains(domain, "/"):
		return ""
	case !strings.Contains(domain, "."):
		return ""
	case strings.Contains(domain, ".."):
		return ""
	case net.ParseIP(domain) != nil:
		return ""
	default:
		return domain
	}
}

func normalizeBlocklistLine(value string) string {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "!") || strings.HasPrefix(raw, "[") || strings.HasPrefix(raw, "@@") {
		return ""
	}

	line := strings.TrimSpace(strings.SplitN(raw, "#", 2)[0])
	if line == "" {
		return ""
	}

	parts := strings.Fields(line)
	if len(parts) >= 2 {
		switch parts[0] {
		case "0.0.0.0", "127.0.0.1", "::", "::1":
			return normalizeDomain(parts[1])
		}
	}

	switch {
	case strings.HasPrefix(line, "||"):
		line = line[2:]
	case strings.HasPrefix(line, "|"):
		line = line[1:]
	}

	switch {
	case strings.HasPrefix(line, "http://"):
		line = strings.TrimPrefix(line, "http://")
	case strings.HasPrefix(line, "https://"):
		line = strings.TrimPrefix(line, "https://")
	}

	if idx := strings.Index(line, "/"); idx >= 0 {
		line = line[:idx]
	}
	if idx := strings.Index(line, "^"); idx >= 0 {
		line = line[:idx]
	}
	if strings.Contains(line, ":") && !strings.HasPrefix(line, "[") {
		line = strings.SplitN(line, ":", 2)[0]
	}
	return normalizeDomain(line)
}

func readDomainsFromText(text string) []string {
	var domains []string
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(strings.NewReader(text))
	for scanner.Scan() {
		domain := normalizeBlocklistLine(scanner.Text())
		if domain == "" {
			continue
		}
		if _, ok := seen[domain]; ok {
			continue
		}
		seen[domain] = struct{}{}
		domains = append(domains, domain)
	}
	return domains
}

func readBlocklist(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return readDomainsFromText(string(data))
}

func readMergedDomains(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var domains []string
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		domain := normalizeDomain(scanner.Text())
		if domain == "" {
			continue
		}
		if _, ok := seen[domain]; ok {
			continue
		}
		seen[domain] = struct{}{}
		domains = append(domains, domain)
	}
	return domains
}

func readRenderedBlocklist(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var domains []string
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		raw := strings.TrimSpace(scanner.Text())
		if raw == "" || strings.HasPrefix(raw, "#") || !strings.HasPrefix(raw, "address=/") {
			continue
		}
		parts := strings.SplitN(raw, "/", 4)
		if len(parts) < 3 {
			continue
		}
		domain := normalizeDomain(parts[1])
		if domain == "" {
			continue
		}
		if _, ok := seen[domain]; ok {
			continue
		}
		seen[domain] = struct{}{}
		domains = append(domains, domain)
	}
	return domains
}

func readURLsFile(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var urls []string
	seen := make(map[string]struct{})
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, "http://") && !strings.HasPrefix(line, "https://") {
			continue
		}
		if _, ok := seen[line]; ok {
			continue
		}
		seen[line] = struct{}{}
		urls = append(urls, line)
	}
	return urls
}

func fetchURLText(rawURL string) (bool, string) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return false, ""
	}
	req.Header.Set("User-Agent", "autoscript-adblock-sync/1.0")
	client := &http.Client{Timeout: defaultHTTPTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return false, ""
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return false, ""
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return false, ""
	}
	return true, string(body)
}

func buildBlocklist(cfg config) ([]string, []string) {
	var merged []string
	seen := make(map[string]struct{})
	var failed []string

	addMany := func(items []string) {
		for _, item := range items {
			if item == "" {
				continue
			}
			if _, ok := seen[item]; ok {
				continue
			}
			seen[item] = struct{}{}
			merged = append(merged, item)
		}
	}

	addMany(readBlocklist(cfg.BlocklistFile))
	for _, url := range cfg.SourceURLs {
		ok, text := fetchURLText(url)
		if !ok {
			failed = append(failed, url)
			continue
		}
		addMany(readDomainsFromText(text))
	}
	return merged, failed
}

func writeAtomicText(path, text string, mode os.FileMode) (bool, error) {
	return writeAtomicBytes(path, []byte(text), mode)
}

func writeAtomicBytes(path string, data []byte, mode os.FileMode) (bool, error) {
	target := filepath.Clean(path)
	existing, err := os.ReadFile(target)
	if err == nil && bytes.Equal(existing, data) {
		return false, nil
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return false, err
	}
	tmp, err := os.CreateTemp(filepath.Dir(target), ".tmp.*")
	if err != nil {
		return false, err
	}
	tmpName := tmp.Name()
	defer func() {
		_ = os.Remove(tmpName)
	}()

	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		return false, err
	}
	if err := tmp.Close(); err != nil {
		return false, err
	}
	if err := os.Chmod(tmpName, mode); err != nil {
		return false, err
	}
	if err := os.Rename(tmpName, target); err != nil {
		return false, err
	}
	return true, nil
}

func renderBlocklist(domains []string, renderedFile string) (bool, error) {
	lines := []string{
		"# generated by adblock-sync",
		"# do not edit directly",
	}
	for _, domain := range domains {
		lines = append(lines, fmt.Sprintf("address=/%s/0.0.0.0", domain))
		lines = append(lines, fmt.Sprintf("address=/%s/::", domain))
	}
	return writeAtomicText(renderedFile, strings.Join(lines, "\n")+"\n", 0o644)
}

func renderMergedDomains(domains []string, mergedFile string) (bool, error) {
	payload := strings.Join(domains, "\n")
	if payload != "" {
		payload += "\n"
	}
	return writeAtomicText(mergedFile, payload, 0o644)
}

func protobufVarint(value uint64) []byte {
	var out []byte
	for {
		b := byte(value & 0x7F)
		value >>= 7
		if value != 0 {
			out = append(out, b|0x80)
			continue
		}
		out = append(out, b)
		return out
	}
}

func protobufKey(fieldNumber, wireType uint64) []byte {
	return protobufVarint((fieldNumber << 3) | wireType)
}

func protobufBytes(fieldNumber uint64, payload []byte) []byte {
	var out []byte
	out = append(out, protobufKey(fieldNumber, 2)...)
	out = append(out, protobufVarint(uint64(len(payload)))...)
	out = append(out, payload...)
	return out
}

func protobufString(fieldNumber uint64, value string) []byte {
	return protobufBytes(fieldNumber, []byte(value))
}

func protobufVarintField(fieldNumber, value uint64) []byte {
	var out []byte
	out = append(out, protobufKey(fieldNumber, 0)...)
	out = append(out, protobufVarint(value)...)
	return out
}

func buildCustomDat(domains []string, code string) []byte {
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" {
		code = "ADBLOCK"
	}
	var geosite bytes.Buffer
	geosite.Write(protobufString(1, code))
	for _, domain := range domains {
		var domainPayload bytes.Buffer
		domainPayload.Write(protobufVarintField(1, 2))
		domainPayload.Write(protobufString(2, domain))
		geosite.Write(protobufBytes(2, domainPayload.Bytes()))
	}
	return protobufBytes(1, geosite.Bytes())
}

func renderCustomDat(domains []string, customDatPath string) (bool, error) {
	return writeAtomicBytes(customDatPath, buildCustomDat(domains, "ADBLOCK"), 0o644)
}

func updateEnvFile(path string, updates map[string]string) error {
	var lines []string
	if data, err := os.ReadFile(path); err == nil {
		lines = strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n")
	}

	var out []string
	seen := make(map[string]struct{})
	for _, line := range lines {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") || !strings.Contains(line, "=") {
			out = append(out, line)
			continue
		}
		key, _, ok := strings.Cut(line, "=")
		if !ok {
			out = append(out, line)
			continue
		}
		key = strings.TrimSpace(key)
		if value, exists := updates[key]; exists {
			out = append(out, fmt.Sprintf("%s=%s", key, value))
			seen[key] = struct{}{}
			continue
		}
		out = append(out, line)
	}
	for key, value := range updates {
		if _, ok := seen[key]; ok {
			continue
		}
		out = append(out, fmt.Sprintf("%s=%s", key, value))
	}
	payload := strings.TrimRight(strings.Join(out, "\n"), "\n") + "\n"
	_, err := writeAtomicText(path, payload, 0o644)
	return err
}

func flushTable(tableName string) {
	_ = runQuietCommand("nft", "delete", "table", "inet", strings.TrimSpace(tableName))
}

func applyTable(tableName string, dnsPort int, users []managedUser) error {
	var builder strings.Builder
	fmt.Fprintf(&builder, "table inet %s {\n", tableName)
	builder.WriteString("  chain output {\n")
	builder.WriteString("    type nat hook output priority dstnat; policy accept;\n")
	for _, user := range users {
		fmt.Fprintf(&builder, "    meta skuid %d udp dport 53 redirect to :%d\n", user.UID, dnsPort)
		fmt.Fprintf(&builder, "    meta skuid %d tcp dport 53 redirect to :%d\n", user.UID, dnsPort)
	}
	builder.WriteString("  }\n")
	builder.WriteString("}\n")

	flushTable(tableName)
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(builder.String())
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}

func ensureDNSServiceLoaded(cfg config, renderedChanged bool) error {
	service := strings.TrimSpace(cfg.DNSService)
	if service == "" || service == "-" || service == "none" {
		return nil
	}
	if renderedChanged {
		if !serviceRestart(service) {
			return fmt.Errorf("Gagal restart DNS Adblock service: %s", service)
		}
		return nil
	}
	if serviceState(service) != "active" {
		_ = serviceStart(service)
	}
	return nil
}

func reloadXrayIfNeeded(cfg config, customChanged, shouldReload bool) error {
	service := strings.TrimSpace(cfg.XrayService)
	if service == "" || service == "-" || service == "none" {
		return nil
	}
	if !shouldReload || !customChanged {
		return nil
	}
	if !serviceRestart(service) {
		return fmt.Errorf("Gagal reload service xray: %s", service)
	}
	if serviceState(service) != "active" {
		return fmt.Errorf("Service xray tidak aktif setelah reload: %s", service)
	}
	return nil
}

func xrayAdblockEnabled() bool {
	data, err := os.ReadFile(defaultXrayRoutingFile)
	if err != nil {
		return false
	}
	var payload map[string]any
	if err := json.Unmarshal(data, &payload); err != nil {
		return false
	}
	routing, _ := payload["routing"].(map[string]any)
	rules, _ := routing["rules"].([]any)
	for _, item := range rules {
		rule, _ := item.(map[string]any)
		if rule == nil {
			continue
		}
		if strings.TrimSpace(fmt.Sprint(rule["type"])) != "field" {
			continue
		}
		domains, _ := rule["domain"].([]any)
		for _, domain := range domains {
			if strings.TrimSpace(fmt.Sprint(domain)) == defaultXrayAdblockRule {
				return true
			}
		}
	}
	return false
}

func materializeArtifacts(cfg config, domains []string) (bool, bool, bool, error) {
	mergedChanged, err := renderMergedDomains(domains, cfg.MergedFile)
	if err != nil {
		return false, false, false, err
	}
	renderedChanged, err := renderBlocklist(domains, cfg.RenderedFile)
	if err != nil {
		return false, false, false, err
	}
	customChanged, err := renderCustomDat(domains, cfg.CustomDat)
	if err != nil {
		return false, false, false, err
	}
	return mergedChanged, renderedChanged, customChanged, nil
}

func applyRuntime(cfg config, refreshSources, reloadXray bool) ([]managedUser, []string, error) {
	if _, err := exec.LookPath("nft"); err != nil {
		return nil, nil, errors.New("nft tidak tersedia")
	}

	renderedChanged := false
	customChanged := false
	var blocklist []string

	if refreshSources {
		var failed []string
		blocklist, failed = buildBlocklist(cfg)
		if len(failed) > 0 {
			return nil, nil, fmt.Errorf("Gagal mengambil source URL adblock: %s", strings.Join(uniqueStrings(failed), ", "))
		}
		var err error
		_, renderedChanged, customChanged, err = materializeArtifacts(cfg, blocklist)
		if err != nil {
			return nil, nil, err
		}
	} else {
		mergedBlocklist := readMergedDomains(cfg.MergedFile)
		if len(mergedBlocklist) > 0 {
			blocklist = mergedBlocklist
			var err error
			renderedChanged, err = renderBlocklist(blocklist, cfg.RenderedFile)
			if err != nil {
				return nil, nil, err
			}
			if !fileExistsNonEmpty(cfg.CustomDat) {
				customChanged, err = renderCustomDat(blocklist, cfg.CustomDat)
				if err != nil {
					return nil, nil, err
				}
			}
		} else {
			renderedBlocklist := readRenderedBlocklist(cfg.RenderedFile)
			if len(renderedBlocklist) > 0 {
				blocklist = renderedBlocklist
				if _, err := renderMergedDomains(blocklist, cfg.MergedFile); err != nil {
					return nil, nil, err
				}
			} else {
				blocklist = readBlocklist(cfg.BlocklistFile)
			}
			var err error
			renderedChanged, err = renderBlocklist(blocklist, cfg.RenderedFile)
			if err != nil {
				return nil, nil, err
			}
			if len(blocklist) > 0 && (len(renderedBlocklist) > 0 || !fileExistsNonEmpty(cfg.CustomDat)) {
				customChanged, err = renderCustomDat(blocklist, cfg.CustomDat)
				if err != nil {
					return nil, nil, err
				}
			}
		}
	}

	if err := ensureDNSServiceLoaded(cfg, renderedChanged); err != nil {
		return nil, nil, err
	}

	users := listManagedUsers(cfg.StateRoot)
	if !cfg.Enabled || len(users) == 0 {
		flushTable(cfg.NFTTable)
	} else if err := applyTable(cfg.NFTTable, cfg.DNSPort, users); err != nil {
		return nil, nil, err
	}

	if refreshSources {
		if err := updateEnvFile(cfg.EnvFile, map[string]string{
			keyDirty:      "0",
			keyLastUpdate: time.Now().UTC().Format("2006-01-02 15:04:05 UTC"),
		}); err != nil {
			return nil, nil, err
		}
		cfg.Dirty = false
	}

	if err := reloadXrayIfNeeded(cfg, customChanged, reloadXray); err != nil {
		return nil, nil, err
	}
	return users, blocklist, nil
}

func printStatus(cfg config) {
	users := listManagedUsers(cfg.StateRoot)
	manualDomains := readBlocklist(cfg.BlocklistFile)
	mergedDomains := readMergedDomains(cfg.MergedFile)
	if len(mergedDomains) == 0 {
		mergedDomains = readRenderedBlocklist(cfg.RenderedFile)
	}
	fmt.Printf("enabled=%d\n", boolInt(cfg.Enabled))
	fmt.Printf("dirty=%d\n", boolInt(cfg.Dirty))
	fmt.Printf("dns_service=%s\n", serviceState(cfg.DNSService))
	fmt.Printf("sync_service=%s\n", serviceState(cfg.SyncService))
	if tableExists(cfg.NFTTable) {
		fmt.Printf("nft_table=present\n")
	} else {
		fmt.Printf("nft_table=absent\n")
	}
	fmt.Printf("bound_users=%d\n", len(users))
	fmt.Printf("users_count=%d\n", len(users))
	fmt.Printf("manual_domains=%d\n", len(manualDomains))
	fmt.Printf("merged_domains=%d\n", len(mergedDomains))
	fmt.Printf("blocklist_entries=%d\n", len(mergedDomains))
	fmt.Printf("source_urls=%d\n", len(cfg.SourceURLs))
	fmt.Printf("dns_port=%d\n", cfg.DNSPort)
	fmt.Printf("blocklist_file=%s\n", cfg.BlocklistFile)
	fmt.Printf("urls_file=%s\n", cfg.URLsFile)
	fmt.Printf("merged_file=%s\n", cfg.MergedFile)
	if fileExists(cfg.RenderedFile) {
		fmt.Printf("rendered_file=ready\n")
	} else {
		fmt.Printf("rendered_file=missing\n")
	}
	if fileExists(cfg.CustomDat) {
		fmt.Printf("custom_dat=ready\n")
	} else {
		fmt.Printf("custom_dat=missing\n")
	}
	fmt.Printf("custom_dat_path=%s\n", cfg.CustomDat)
	fmt.Printf("auto_update_enabled=%d\n", boolInt(cfg.AutoUpdateEnabled))
	fmt.Printf("auto_update_service=%s\n", serviceState(cfg.AutoUpdateService))
	fmt.Printf("auto_update_timer=%s\n", serviceState(cfg.AutoUpdateTimer))
	fmt.Printf("auto_update_days=%d\n", cfg.AutoUpdateDays)
	fmt.Printf("auto_update_schedule=every %d day(s)\n", cfg.AutoUpdateDays)
	lastUpdate := strings.TrimSpace(cfg.LastUpdate)
	if lastUpdate == "" {
		lastUpdate = "-"
	}
	fmt.Printf("last_update=%s\n", lastUpdate)
}

func printUsers(cfg config) {
	for _, user := range listManagedUsers(cfg.StateRoot) {
		fmt.Printf("%s|%d\n", user.Username, user.UID)
	}
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func fileExistsNonEmpty(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.Size() > 0
}

func uniqueStrings(items []string) []string {
	seen := make(map[string]struct{})
	var out []string
	for _, item := range items {
		if _, ok := seen[item]; ok {
			continue
		}
		seen[item] = struct{}{}
		out = append(out, item)
	}
	return out
}

func runQuietCommand(name string, args ...string) error {
	filtered := make([]string, 0, len(args))
	for _, arg := range args {
		if strings.TrimSpace(arg) == "" {
			continue
		}
		filtered = append(filtered, arg)
	}
	cmd := exec.Command(name, filtered...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}
