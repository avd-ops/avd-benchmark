// Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace AvdBenchmark.FixtureApp
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string scratchDir = args.Length > 0 ? args[0] : Path.GetTempPath();
            Application.Run(new FixtureForm(scratchDir));
        }
    }

    internal sealed class FixtureForm : Form
    {
        private readonly string _scratchDir;
        private readonly TextBox _editor;
        private readonly TextBox _filterBox;
        private readonly ListBox _list;
        private readonly TabControl _tabs;
        private readonly Button _saveButton;
        private readonly Label _statusLabel;

        public FixtureForm(string scratchDir)
        {
            _scratchDir = scratchDir;
            Name = "AvdBenchmarkFixtureMain";
            Text = "AVD Benchmark Fixture";
            Size = new Size(720, 480);
            StartPosition = FormStartPosition.CenterScreen;

            _tabs = new TabControl { Name = "FixtureTabs", Dock = DockStyle.Fill };
            var tabEdit = new TabPage("Editor") { Name = "TabEditor" };
            var tabList = new TabPage("Catalog") { Name = "TabCatalog" };

            _editor = new TextBox
            {
                Name = "FixtureEditor",
                Multiline = true,
                ScrollBars = ScrollBars.Vertical,
                Dock = DockStyle.Fill
            };

            var bottomPanel = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 38 };
            _saveButton = new Button { Name = "SaveFixtureButton", Text = "Save", Width = 90 };
            _saveButton.Click += OnSaveClick;
            _statusLabel = new Label { Name = "StatusLabel", Text = "Ready", AutoSize = true, Padding = new Padding(8, 6, 0, 0) };
            bottomPanel.Controls.Add(_saveButton);
            bottomPanel.Controls.Add(_statusLabel);

            tabEdit.Controls.Add(_editor);
            tabEdit.Controls.Add(bottomPanel);

            _filterBox = new TextBox { Name = "FilterBox", Dock = DockStyle.Top };
            _filterBox.TextChanged += OnFilterChanged;
            _list = new ListBox { Name = "FixtureList", Dock = DockStyle.Fill };
            PopulateList(string.Empty);
            tabList.Controls.Add(_list);
            tabList.Controls.Add(_filterBox);

            _tabs.TabPages.Add(tabEdit);
            _tabs.TabPages.Add(tabList);
            Controls.Add(_tabs);
        }

        private void PopulateList(string filter)
        {
            _list.BeginUpdate();
            _list.Items.Clear();
            for (int i = 1; i <= 200; i++)
            {
                string item = "item-" + i.ToString("D3");
                if (string.IsNullOrEmpty(filter) || item.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    _list.Items.Add(item);
                }
            }
            _list.EndUpdate();
        }

        private void OnFilterChanged(object sender, EventArgs e)
        {
            PopulateList(_filterBox.Text);
        }

        private void OnSaveClick(object sender, EventArgs e)
        {
            Directory.CreateDirectory(_scratchDir);
            string target = Path.Combine(_scratchDir, "fixture-doc.txt");
            File.WriteAllText(target, _editor.Text ?? string.Empty);
            _statusLabel.Text = "Saved";
        }
    }
}
