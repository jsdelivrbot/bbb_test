################################################################################
#
# erlang
#
################################################################################

# See note below when updating Erlang
ERLANG_VERSION = 19.2
ERLANG_SITE = http://www.erlang.org/download
ERLANG_SOURCE = otp_src_$(ERLANG_VERSION).tar.gz
ERLANG_DEPENDENCIES = host-erlang

ERLANG_LICENSE = Apache-2.0
ERLANG_LICENSE_FILES = LICENSE.txt
ERLANG_INSTALL_STAGING = YES

# Patched erts/aclocal.m4
ERLANG_AUTORECONF = YES

# Whenever updating Erlang, this value should be updated as well, to the
# value of EI_VSN in the file lib/erl_interface/vsn.mk
ERLANG_EI_VSN = 3.9.2

# The configure checks for these functions fail incorrectly
ERLANG_CONF_ENV = ac_cv_func_isnan=yes ac_cv_func_isinf=yes \
		  i_cv_posix_fallocate_works=yes

# Set erl_xcomp variables. See xcomp/erl-xcomp.conf.template
# for documentation.
ERLANG_CONF_ENV += erl_xcomp_sysroot=$(STAGING_DIR)

# Support for CLOCK_THREAD_CPUTIME_ID cannot be autodetected for
# crosscompiling. The man page for clock_gettime(3) indicates that
# Linux 2.6.12 and later support this.
ERLANG_CONF_ENV += erl_xcomp_clock_gettime_cpu_time=yes

ERLANG_CONF_OPTS = --without-javac

# erlang uses openssl for all things crypto. Since the host tools (such as
# rebar) uses crypto, we need to build host-erlang with support for openssl.
HOST_ERLANG_DEPENDENCIES = host-openssl
HOST_ERLANG_CONF_OPTS = --without-javac --with-ssl=$(HOST_DIR)/usr

HOST_ERLANG_CONF_OPTS += --without-termcap

ifeq ($(BR2_TOOLCHAIN_HAS_THREADS),)
ERLANG_CONF_OPTS += --disable-threads
endif

ifeq ($(BR2_PACKAGE_NCURSES),y)
ERLANG_CONF_OPTS += --with-termcap
ERLANG_DEPENDENCIES += ncurses
else
ERLANG_CONF_OPTS += --without-termcap
endif

ifeq ($(BR2_PACKAGE_OPENSSL),y)
ERLANG_CONF_OPTS += --with-ssl
ERLANG_DEPENDENCIES += openssl
else
ERLANG_CONF_OPTS += --without-ssl
endif

ifeq ($(BR2_PACKAGE_UNIXODBC),y)
ERLANG_DEPENDENCIES += unixodbc
endif

ifeq ($(BR2_PACKAGE_ZLIB),y)
ERLANG_CONF_OPTS += --enable-shared-zlib
ERLANG_DEPENDENCIES += zlib
endif

ifeq ($(BR2_PACKAGE_ERLANG_SMP),)
ERLANG_CONF_OPTS += --disable-smp-support
endif

# Remove source, example, gs and wx files from staging and target.
ERLANG_REMOVE_PACKAGES = gs wx

ifneq ($(BR2_PACKAGE_ERLANG_MEGACO),y)
ERLANG_REMOVE_PACKAGES += megaco
endif

define ERLANG_REMOVE_STAGING_UNUSED
	# Remove intermediate build products that can get copied Erlang
	# release tools.
	find $(STAGING_DIR)/usr/lib/erlang -type d -name obj -prune -exec rm -rf {} \;

	# Remove unwanted packages from being found by the Erlang compiler
	for package in $(ERLANG_REMOVE_PACKAGES); do \
		rm -rf $(STAGING_DIR)/usr/lib/erlang/lib/$${package}-*; \
	done
endef

define ERLANG_REMOVE_TARGET_UNUSED
	# Remove top level installation files
	rm -rf $(TARGET_DIR)/usr/lib/erlang/misc
	rm -f $(TARGET_DIR)/usr/lib/erlang/Install

	# Remove intermediate build products
	find $(TARGET_DIR)/usr/lib/erlang -type d -name obj -prune -exec rm -rf {} \;
	find $(TARGET_DIR)/usr/lib/erlang -name "*.a" -delete

	# Remove source and documentation
	find $(TARGET_DIR)/usr/lib/erlang -name "*.h" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "*.idl" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "*.mk" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "*.erl" -delete
	find $(TARGET_DIR)/usr/lib/erlang -name "README" -delete
	for dir in $(TARGET_DIR)/usr/lib/erlang/erts-* \
		   $(TARGET_DIR)/usr/lib/erlang/lib/*; do \
		rm -rf $${dir}/src $${dir}/c_src $${dir}/doc \
		       $${dir}/man $${dir}/examples $${dir}/emacs; \
	done

	# Remove unwanted packages
	for package in $(ERLANG_REMOVE_PACKAGES); do \
		rm -rf $(TARGET_DIR)/usr/lib/erlang/lib/$${package}-*; \
	done

	# Remove all folders that are now empty
	find $(TARGET_DIR)/usr/lib/erlang -type d -empty -delete
endef

ERLANG_POST_INSTALL_STAGING_HOOKS += ERLANG_REMOVE_STAGING_UNUSED
ERLANG_POST_INSTALL_TARGET_HOOKS += ERLANG_REMOVE_TARGET_UNUSED

$(eval $(autotools-package))
$(eval $(host-autotools-package))
