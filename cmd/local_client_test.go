package cmd_test

import (
	"flag"
	"os"
	"testing"

	"github.com/smartcontractkit/chainlink/cmd"
	"github.com/smartcontractkit/chainlink/internal/cltest"
	"github.com/smartcontractkit/chainlink/store"
	"github.com/stretchr/testify/assert"
	"github.com/urfave/cli"
)

func TestClient_RunNodeShowsEnv(t *testing.T) {
	config, configCleanup := cltest.NewConfig()
	defer configCleanup()
	config.LinkContractAddress = "0x514910771AF9Ca656af840dff83E8264EcF986CA"
	config.Port = "6688"

	app, cleanup := cltest.NewApplicationWithConfigAndKeyStore(config)
	defer cleanup()

	r := &cltest.RendererMock{}
	auth := cltest.CallbackAuthenticator{Callback: func(*store.Store, string) error { return nil }}
	client := cmd.Client{
		Renderer:        r,
		Config:          app.Store.Config,
		AppFactory:      cltest.InstanceAppFactory{App: app.ChainlinkApplication},
		Auth:            auth,
		UserInitializer: &cltest.MockUserInitializer{},
		Runner:          cltest.EmptyRunner{},
		RemoteClient:    cltest.NewMockAuthenticatedRemoteClient(app.Store.Config),
	}

	set := flag.NewFlagSet("test", 0)
	set.Bool("debug", true, "")
	c := cli.NewContext(nil, set, nil)

	eth := app.MockEthClient()
	eth.Register("eth_getTransactionCount", `0x1`)

	assert.NoError(t, client.RunNode(c))

	logs, err := cltest.ReadLogs(app)
	assert.NoError(t, err)

	assert.Contains(t, logs, "LOG_LEVEL: debug\\n")
	assert.Contains(t, logs, "ROOT: /tmp/chainlink_test/")
	assert.Contains(t, logs, "CHAINLINK_PORT: 6688\\n")
	assert.Contains(t, logs, "ETH_URL: ws://")
	assert.Contains(t, logs, "ETH_CHAIN_ID: 3\\n")
	assert.Contains(t, logs, "CLIENT_NODE_URL: http://")
	assert.Contains(t, logs, "TX_MIN_CONFIRMATIONS: 6\\n")
	assert.Contains(t, logs, "TASK_MIN_CONFIRMATIONS: 0\\n")
	assert.Contains(t, logs, "ETH_GAS_BUMP_THRESHOLD: 3\\n")
	assert.Contains(t, logs, "ETH_GAS_BUMP_WEI: 5000000000\\n")
	assert.Contains(t, logs, "ETH_GAS_PRICE_DEFAULT: 20000000000\\n")
	assert.Contains(t, logs, "LINK_CONTRACT_ADDRESS: 0x514910771AF9Ca656af840dff83E8264EcF986CA\\n")
	assert.Contains(t, logs, "MINIMUM_CONTRACT_PAYMENT: 0\\n")
	assert.Contains(t, logs, "ORACLE_CONTRACT_ADDRESS: \\n")
	assert.Contains(t, logs, "DATABASE_POLL_INTERVAL: 500ms\\n")
	assert.Contains(t, logs, "ALLOW_ORIGINS: http://localhost:3000,http://localhost:6689\\n")
}

func TestClient_RunNodeWithPasswords(t *testing.T) {
	tests := []struct {
		name         string
		pwdfile      string
		wantUnlocked bool
	}{
		{"correct", "../internal/fixtures/correct_password.txt", true},
		{"incorrect", "../internal/fixtures/incorrect_password.txt", false},
		{"wrongfile", "doesntexist.txt", false},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			app, _ := cltest.NewApplication() // cleanup invoked in client.RunNode
			_, err := app.Store.KeyStore.NewAccount("password")
			assert.NoError(t, err)
			r := &cltest.RendererMock{}
			eth := app.MockEthClient()
			app.MustSeedUserSession()

			var unlocked bool
			callback := func(store *store.Store, phrase string) error {
				err := store.KeyStore.Unlock(phrase)
				unlocked = err == nil
				return err
			}

			auth := cltest.CallbackAuthenticator{Callback: callback}
			apiInitializer := &cltest.MockUserInitializer{}
			client := cmd.Client{
				Renderer:        r,
				Config:          app.Store.Config,
				AppFactory:      cltest.InstanceAppFactory{App: app},
				Auth:            auth,
				UserInitializer: apiInitializer,
				Runner:          cltest.EmptyRunner{},
				RemoteClient:    cltest.NewMockAuthenticatedRemoteClient(app.Store.Config),
			}

			set := flag.NewFlagSet("test", 0)
			set.String("password", test.pwdfile, "")
			c := cli.NewContext(nil, set, nil)

			eth.Register("eth_getTransactionCount", `0x1`)
			if test.wantUnlocked {
				assert.NoError(t, client.RunNode(c))
				assert.True(t, unlocked)
				assert.Equal(t, 1, apiInitializer.Count)
			} else {
				assert.Error(t, client.RunNode(c))
				assert.False(t, unlocked)
				assert.Equal(t, 0, apiInitializer.Count)
			}
		})
	}
}

func TestClient_ImportKey(t *testing.T) {
	t.Parallel()

	app, cleanup := cltest.NewApplication()
	defer cleanup()
	client, _ := app.NewClientAndRenderer()

	os.MkdirAll(app.Store.Config.KeysDir(), os.FileMode(0700))

	set := flag.NewFlagSet("import", 0)
	set.Parse([]string{"../internal/fixtures/keys/3cb8e3fd9d27e39a5e9e6852b0e96160061fd4ea.json"})
	c := cli.NewContext(nil, set, nil)
	assert.Nil(t, client.ImportKey(c))
	assert.Error(t, client.ImportKey(c))
}
