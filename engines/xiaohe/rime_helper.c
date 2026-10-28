// rime_helper — 小鹤双拼引擎的 RIME 辅助进程（由 ime_eval/rime_probe.c 而来）。经标准输入输出驱动 librime，
// 每行一条命令，用 Tab 分隔：
//
//   menu <keys> <k>     clear, type <keys>, print up to <k> candidates
// The reply is one line of tab-separated candidate texts.
//
//   cc -O2 -o rime_helper rime_helper.c $(pkg-config --cflags --libs rime)
//   ./rime_helper <共享数据目录（雾凇词库）> <用户数据目录（引擎数据目录下）> <方案名>

#include <rime_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static RimeApi *rime;
static RimeSessionId session;

static void type_keys(const char *keys) {
  rime->clear_composition(session);
  rime->simulate_key_sequence(session, keys);
}

static void cmd_menu(const char *keys, int k) {
  type_keys(keys);
  RimeCandidateListIterator it = {0};
  int n = 0;
  if (rime->candidate_list_begin(session, &it)) {
    while (n < k && rime->candidate_list_next(&it)) {
      printf("%s%s", n ? "\t" : "", it.candidate.text);
      n++;
    }
    rime->candidate_list_end(&it);
  }
  printf("\n");
}

int main(int argc, char **argv) {
  if (argc < 4) {
    fprintf(stderr, "usage: %s shared_data_dir user_data_dir schema_id\n", argv[0]);
    return 64;
  }
  rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.log_dir = argv[2];
  traits.distribution_name = "luoke-xiaohe";
  traits.distribution_code_name = "luoke-xiaohe";
  traits.distribution_version = "0.1";
  traits.app_name = "rime.luoke-xiaohe";
  traits.min_log_level = 2;
  rime->setup(&traits);
  rime->initialize(&traits);
  if (rime->start_maintenance(True)) rime->join_maintenance_thread();
  session = rime->create_session();
  if (!session || !rime->select_schema(session, argv[3])) {
    fprintf(stderr, "cannot select schema %s\n", argv[3]);
    return 70;
  }
  rime->set_option(session, "ascii_mode", False);
  fprintf(stderr, "ready\n");
  fflush(stderr);

  char line[4096];
  while (fgets(line, sizeof line, stdin)) {
    line[strcspn(line, "\n")] = 0;
    char *cmd = strtok(line, "\t"), *keys = strtok(NULL, "\t"), *arg = strtok(NULL, "\t");
    if (!cmd || !keys) { printf("\n"); fflush(stdout); continue; }
    int n = arg ? atoi(arg) : 0;
    if (!strcmp(cmd, "menu")) cmd_menu(keys, n ? n : 10);
    else printf("\n");
    fflush(stdout);
  }
  rime->destroy_session(session);
  rime->finalize();
  return 0;
}
