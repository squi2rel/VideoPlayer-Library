#include <dlfcn.h>
#include <jni.h>

typedef jint (*jni_onload_t)(JavaVM *, void *);

JNIEXPORT void JNICALL
Java_com_github_squi2rel_vp_Android_init(JNIEnv *env, jclass clazz) {
    (void)clazz;

    JavaVM *vm = NULL;
    if ((*env)->GetJavaVM(env, &vm) != JNI_OK || vm == NULL) {
        return;
    }

    void *handle = dlopen("libvlc.so", RTLD_NOW);
    if (handle == NULL) {
        return;
    }

    jni_onload_t onload = (jni_onload_t)dlsym(handle, "JNI_OnLoad");
    if (onload != NULL) {
        onload(vm, NULL);
    }
}
